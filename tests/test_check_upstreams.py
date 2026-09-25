"""scripts/check_upstreams.py counts an upstream's new commits from a local
mirror; here the "upstream" is a throwaway repository on disk, so no test
touches the network."""

from __future__ import annotations

import importlib.util
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def _script():
    spec = importlib.util.spec_from_file_location("check_upstreams", ROOT / "scripts" / "check_upstreams.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _commit(repo: Path, message: str) -> str:
    (repo / "file.txt").write_text(message)
    subprocess.run(["git", "add", "."], cwd=repo, check=True, capture_output=True, timeout=30)
    subprocess.run(
        ["git", "-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-qm", message],
        cwd=repo, check=True, capture_output=True, timeout=30,
    )
    return subprocess.run(["git", "rev-parse", "HEAD"], cwd=repo, check=True, capture_output=True,
                          text=True, timeout=30).stdout.strip()


def test_new_commits_since_the_recorded_ref_are_counted(tmp_path: Path, capsys) -> None:
    script = _script()
    upstream = tmp_path / "upstream"
    upstream.mkdir()
    subprocess.run(["git", "init", "-q", "-b", "main"], cwd=upstream, check=True, capture_output=True, timeout=30)
    baseline = _commit(upstream, "first")
    _commit(upstream, "second")
    _commit(upstream, "third")
    sources = tmp_path / "sources.json"
    sources.write_text(json.dumps([["example/upstream", upstream.as_uri(), baseline]]))

    assert script.main(["--offline", "--cache", str(tmp_path / "cache"), "--sources", str(sources)]) == 1
    assert "not cached yet" in capsys.readouterr().out

    code = script.main(["--json", "--cache", str(tmp_path / "cache"), "--sources", str(sources)])
    document = json.loads(capsys.readouterr().out)
    assert code == 0
    [row] = document["sources"]
    assert row["new_commits"] == 2
    assert row["since"] == baseline
    assert [line.split(" ", 2)[2] for line in row["recent"]] == ["third", "second"]


def test_a_newer_review_doc_supplies_the_refs(tmp_path: Path) -> None:
    script = _script()
    review = tmp_path / "docs" / "UPSTREAM-REFRESH-2026-10-30.md"
    review.parent.mkdir()
    sha = "a" * 40
    review.write_text(f"| CodexBar | `steipete/CodexBar`, main at `{sha}` |\n| T3 | no hash here |\n")

    assert script.latest_review(tmp_path) == review
    assert script.recorded_refs(review) == {"steipete/CodexBar": sha}
