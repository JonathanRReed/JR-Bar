#!/usr/bin/env python3
"""How far each upstream JR-Bar learns from has moved since the last review.

Read-only toward every upstream: it keeps a blobless bare copy of each one
under ``~/.cache/jrbar/upstreams`` (``git clone``/``git fetch``, nothing is
ever pushed) and prints the commits since the ref the last review recorded.
The ref comes from the newest ``docs/UPSTREAM-REFRESH-*.md`` (in ``docs/`` or
``docs/archive/``) when that doc names a full commit hash on the source's
line and is newer than the baseline below (the 2026-09-24 OSS research),
else from that baseline. There is
no timer and no CI job: docs/UPSTREAM-RESEARCH-CADENCE.md keeps the review
manual, and this is a helper for it.

    scripts/check_upstreams.py              fetch, then report
    scripts/check_upstreams.py --offline    report from the cached copies only
    scripts/check_upstreams.py --json
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CACHE = Path.home() / ".cache" / "jrbar" / "upstreams"

#: (name, clone URL, baseline ref) for each upstream.
UPSTREAMS = (
    ("steipete/CodexBar", "https://github.com/steipete/CodexBar.git", "e34fe618"),
    ("pingdotgg/t3code", "https://github.com/pingdotgg/t3code.git", "cb1a3f34"),
    ("router-for-me/CLIProxyAPI", "https://github.com/router-for-me/CLIProxyAPI.git", "c404af96"),
    ("ryoppippi/ccusage", "https://github.com/ryoppippi/ccusage.git", "03f421fa"),
    ("inteliwear/sidepulse", "https://github.com/inteliwear/sidepulse.git",
     "044508556934f913ac555d555e35e19b23294773"),
)
#: When the baselines above were recorded. A review doc newer than this
#: supplies the refs instead.
BASELINE_DATE = "2026-09-24"
_SHA = re.compile(r"\b[0-9a-f]{40}\b")
_REVIEW_DATE = re.compile(r"UPSTREAM-REFRESH-(\d{4}-\d{2}-\d{2})")


def latest_review(root: Path = ROOT) -> Path | None:
    docs = sorted(
        [*root.glob("docs/UPSTREAM-REFRESH-*.md"), *root.glob("docs/archive/UPSTREAM-REFRESH-*.md")],
        key=lambda path: path.name,
    )
    return docs[-1] if docs else None


def recorded_refs(review: Path | None) -> dict[str, str]:
    """``owner/repo`` -> the first full hash on a line that names it."""
    if review is None:
        return {}
    refs: dict[str, str] = {}
    for line in review.read_text(encoding="utf-8", errors="replace").splitlines():
        for name, _url, _baseline in UPSTREAMS:
            if name.lower() in line.lower() and name not in refs:
                match = _SHA.search(line)
                if match:
                    refs[name] = match.group(0)
    return refs


def _git(*args: str, cwd: Path | None = None) -> str:
    completed = subprocess.run(
        ["git", *args], cwd=cwd, capture_output=True, text=True, timeout=300, check=False
    )
    if completed.returncode != 0:
        raise RuntimeError(completed.stderr.strip() or f"git {' '.join(args)} failed")
    return completed.stdout


def mirror(name: str, url: str, *, cache: Path, offline: bool) -> Path:
    target = cache / (name.replace("/", "__") + ".git")
    if offline:
        if not target.is_dir():
            raise RuntimeError("not cached yet; run once without --offline")
        return target
    if target.is_dir():
        _git("fetch", "--quiet", "--prune", "origin", "+refs/heads/*:refs/heads/*", cwd=target)
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        _git("clone", "--quiet", "--bare", "--filter=blob:none", url, str(target))
    return target


def report(name: str, repo: Path, since: str) -> dict[str, object]:
    head = _git("rev-parse", "HEAD", cwd=repo).strip()
    try:
        count = int(_git("rev-list", "--count", f"{since}..HEAD", cwd=repo).strip())
        recent = _git("log", "--format=%h %ad %s", "--date=short", "-n", "8", f"{since}..HEAD", cwd=repo).splitlines()
    except RuntimeError:
        return {"source": name, "head": head, "since": since, "error": "the recorded ref is not in this history"}
    return {"source": name, "head": head, "since": since, "new_commits": count, "recent": recent}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--cache", type=Path, default=CACHE)
    parser.add_argument("--sources", type=Path, help=argparse.SUPPRESS)
    options = parser.parse_args(argv)
    sources = UPSTREAMS
    if options.sources is not None:
        sources = tuple(tuple(row) for row in json.loads(options.sources.read_text()))
    review = latest_review()
    dated = _REVIEW_DATE.search(review.name) if review is not None else None
    newer = dated is not None and dated.group(1) > BASELINE_DATE
    refs = recorded_refs(review) if newer else {}
    rows = []
    for name, url, baseline in sources:
        since = refs.get(name, baseline)
        try:
            repo = mirror(name, url, cache=options.cache, offline=options.offline)
            rows.append(report(name, repo, since))
        except (RuntimeError, OSError, subprocess.SubprocessError) as error:
            rows.append({"source": name, "since": since, "error": str(error)})
    if options.json:
        print(json.dumps({"review": str(review) if review else None, "sources": rows}, indent=2))
    else:
        print(f"last review: {review.name if review else 'none found'}")
        for row in rows:
            if "error" in row:
                print(f"{row['source']}: {row['error']}")
                continue
            print(f"{row['source']}: {row['new_commits']} new commit(s) since {row['since'][:8]}")
            for line in row["recent"]:
                print(f"    {line}")
    return 1 if any("error" in row for row in rows) else 0


if __name__ == "__main__":
    sys.exit(main())
