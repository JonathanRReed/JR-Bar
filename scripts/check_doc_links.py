#!/usr/bin/env python3
"""Every relative link in the repository's Markdown points at something.

Checks ``[text](path)`` and ``[text](path#heading)`` links (and reference
definitions, ``[name]: path``) in every tracked-looking ``*.md`` outside
build output: the file must exist, and a ``#heading`` must name a heading
in that Markdown file (GitHub's slug rules). Web links, ``mailto:`` and
code blocks are skipped. ``make fast`` runs it, so a doc move that strands
a link fails before it merges (CodexBar's check-documentation-links and
ccusage's lychee job are the idea; this is our own).

    scripts/check_doc_links.py            report and exit 1 on a broken link
    scripts/check_doc_links.py --root DIR
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
_SKIP_PARTS = frozenset({".git", ".build", "build", "dist", "node_modules", ".venv", ".jrbar-verification"})
_FENCE = re.compile(r"^(```|~~~).*?^\1", re.MULTILINE | re.DOTALL)
_INLINE_CODE = re.compile(r"`[^`\n]*`")
_LINK = re.compile(r"(?<!!)\[[^\]\n]*\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
_REFERENCE = re.compile(r"^\s{0,3}\[[^\]\n]+\]:\s*<?(\S+?)>?(?:\s+\"[^\"]*\")?\s*$", re.MULTILINE)
_HEADING = re.compile(r"^#{1,6}\s+(.*?)\s*#*\s*$", re.MULTILINE)
_SCHEME = re.compile(r"^[a-z][a-z0-9+.-]*:", re.IGNORECASE)


def slug(heading: str) -> str:
    """GitHub's anchor for a heading: lowercase, punctuation dropped,
    spaces to hyphens."""
    text = re.sub(r"<[^>]+>", "", heading).strip().lower()
    text = re.sub(r"[^\w\- ]", "", text)
    return text.replace(" ", "-")


def _prose(text: str) -> str:
    return _INLINE_CODE.sub("", _FENCE.sub("", text))


def markdown_files(root: Path) -> list[Path]:
    return sorted(
        path
        for path in root.rglob("*.md")
        if not (_SKIP_PARTS & set(path.relative_to(root).parts))
    )


def anchors(path: Path, cache: dict[Path, set[str]]) -> set[str]:
    if path not in cache:
        text = _FENCE.sub("", path.read_text(encoding="utf-8", errors="replace"))
        found: set[str] = set()
        counts: dict[str, int] = {}
        for heading in _HEADING.findall(text):
            base = slug(heading)
            index = counts.get(base, 0)
            counts[base] = index + 1
            found.add(base if index == 0 else f"{base}-{index}")
        cache[path] = found
    return cache[path]


def broken_links(root: Path) -> list[tuple[Path, str, str]]:
    problems: list[tuple[Path, str, str]] = []
    cache: dict[Path, set[str]] = {}
    for source in markdown_files(root):
        text = _prose(source.read_text(encoding="utf-8", errors="replace"))
        targets = [*_LINK.findall(text), *_REFERENCE.findall(text)]
        for target in targets:
            if _SCHEME.match(target) or target.startswith("//"):
                continue
            path_part, _, anchor = target.partition("#")
            destination = source if not path_part else (source.parent / path_part)
            if path_part.startswith("/"):
                destination = root / path_part.lstrip("/")
            if not destination.exists():
                problems.append((source, target, "no such file"))
                continue
            if anchor and destination.suffix.lower() == ".md" and destination.is_file():
                if anchor.lower() not in anchors(destination, cache):
                    problems.append((source, target, "no such heading"))
    return problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=ROOT)
    options = parser.parse_args(argv)
    root = options.root.resolve()
    problems = broken_links(root)
    for source, target, why in problems:
        print(f"{source.relative_to(root)}: {target} ({why})")
    count = len(markdown_files(root))
    if problems:
        print(f"{len(problems)} broken link(s) in {count} Markdown files", file=sys.stderr)
        return 1
    print(f"doc links: {count} Markdown files, every relative link resolves")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
