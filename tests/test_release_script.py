"""scripts/release.sh refuses an unready release and, in a dry run,
publishes nothing. Every run here is a dry run in a throwaway repository."""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "release.sh"


def _git(repo: Path, *args: str) -> None:
    subprocess.run(["git", *args], cwd=repo, check=True, capture_output=True, timeout=30)


def _repo(tmp_path: Path, *, changelog_top: str = "## 1.2.3 (2026-09-24)") -> Path:
    repo = tmp_path / "repo"
    (repo / "scripts").mkdir(parents=True)
    shutil.copy2(SCRIPT, repo / "scripts" / "release.sh")
    (repo / "pyproject.toml").write_text('[project]\nname = "jrbar"\nversion = "1.2.3"\n')
    (repo / "CHANGELOG.md").write_text(
        f"# Changelog\n\n{changelog_top}\n\n- The usage hooks run without a shell.\n\n## 1.2.2\n\n- Older.\n"
    )
    (repo / ".gitignore").write_text("dist/\n")
    _git(repo, "init", "-q")
    _git(repo, "-c", "user.email=t@example.com", "-c", "user.name=t", "add", ".")
    _git(repo, "-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-qm", "one")
    return repo


def _dry_run(repo: Path) -> subprocess.CompletedProcess:
    env = {**os.environ, "JRBAR_RELEASE_SKIP_REMOTE": "1", "PYTHON": shutil.which("python3") or "python3"}
    env.pop("JRBAR_BUILD_NUMBER", None)
    return subprocess.run(
        ["/bin/bash", str(repo / "scripts" / "release.sh"), "--dry-run"],
        cwd=repo, env=env, capture_output=True, text=True, timeout=60, check=False,
    )


def test_the_script_parses() -> None:
    assert subprocess.run(["/bin/bash", "-n", str(SCRIPT)], capture_output=True, timeout=30).returncode == 0


def test_a_ready_tree_passes_and_writes_the_notes(tmp_path: Path) -> None:
    repo = _repo(tmp_path)

    result = _dry_run(repo)

    assert result.returncode == 0, result.stderr
    assert "nothing was published" in result.stdout
    assert "would run: scripts/publish_release.sh" in result.stdout
    notes = (repo / "dist" / "release-notes-1.2.3.md").read_text()
    assert notes.strip() == "- The usage hooks run without a shell."


def test_an_unreleased_changelog_is_refused(tmp_path: Path) -> None:
    repo = _repo(tmp_path, changelog_top="## 1.2.3 (unreleased)")
    result = _dry_run(repo)
    assert result.returncode == 1 and "unreleased" in result.stderr


def test_a_changelog_for_another_version_is_refused(tmp_path: Path) -> None:
    repo = _repo(tmp_path, changelog_top="## 1.2.4")
    result = _dry_run(repo)
    assert result.returncode == 1 and "not '## 1.2.3'" in result.stderr


def test_a_dirty_tree_is_refused(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    (repo / "stray.txt").write_text("x")
    result = _dry_run(repo)
    assert result.returncode == 1 and "dirty" in result.stderr


@pytest.mark.parametrize("existing", ["v1.2.3"])
def test_an_existing_tag_is_refused(tmp_path: Path, existing: str) -> None:
    repo = _repo(tmp_path)
    _git(repo, "tag", existing)
    result = _dry_run(repo)
    assert result.returncode == 1 and "already exists" in result.stderr


def test_a_build_that_does_not_go_up_is_refused(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    _git(repo, "tag", "v1.2.2")  # the last release, at the same commit
    result = _dry_run(repo)
    assert result.returncode == 1 and "not higher" in result.stderr
