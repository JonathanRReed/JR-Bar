"""scripts/release.sh refuses an unready release and, in a dry run,
publishes nothing. Every run here is in a throwaway repository."""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "release.sh"

_IDENTITY = ("-c", "user.email=t@example.com", "-c", "user.name=t")


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
    # The release is cut from main whatever init.defaultBranch says here.
    _git(repo, "init", "-q", "-b", "main")
    _git(repo, *_IDENTITY, "add", ".")
    _git(repo, *_IDENTITY, "commit", "-qm", "one")
    return repo


def _stub_gh(tmp_path: Path) -> Path:
    """A `gh` on PATH so a dry run does not depend on the host having one."""
    folder = tmp_path / "gh-bin"
    folder.mkdir(exist_ok=True)
    gh = folder / "gh"
    gh.write_text("#!/bin/sh\nexit 99\n")
    gh.chmod(0o755)
    return folder


def _env(tmp_path: Path, *, skip_remote: bool = True, path: str | None = None) -> dict[str, str]:
    env = {**os.environ, "PYTHON": shutil.which("python3") or "python3"}
    env["PATH"] = path if path is not None else f"{_stub_gh(tmp_path)}{os.pathsep}{os.environ['PATH']}"
    if skip_remote:
        env["JRBAR_RELEASE_SKIP_REMOTE"] = "1"
    else:
        env.pop("JRBAR_RELEASE_SKIP_REMOTE", None)
    env.pop("JRBAR_BUILD_NUMBER", None)
    return env


def _release(repo: Path, env: dict[str, str], *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["/bin/bash", str(repo / "scripts" / "release.sh"), *args],
        cwd=repo, env=env, capture_output=True, text=True, timeout=60, check=False,
    )


def _dry_run(repo: Path, tmp_path: Path) -> subprocess.CompletedProcess:
    return _release(repo, _env(tmp_path), "--dry-run")


def test_the_script_parses() -> None:
    assert subprocess.run(["/bin/bash", "-n", str(SCRIPT)], capture_output=True, timeout=30).returncode == 0


def test_a_ready_tree_passes_and_writes_the_notes(tmp_path: Path) -> None:
    repo = _repo(tmp_path)

    result = _dry_run(repo, tmp_path)

    assert result.returncode == 0, result.stderr
    assert "nothing was published" in result.stdout
    assert "would run: scripts/publish_release.sh" in result.stdout
    notes = (repo / "dist" / "release-notes-1.2.3.md").read_text()
    assert notes.strip() == "- The usage hooks run without a shell."


def test_a_dry_run_does_not_claim_checks_it_does_not_make(tmp_path: Path) -> None:
    repo = _repo(tmp_path)

    result = _dry_run(repo, tmp_path)

    assert result.returncode == 0, result.stderr
    assert "every check passed" not in result.stdout
    # What waits for publish time is named, so a green dry run is not read as a green release.
    assert "release gate" in result.stdout and "when you publish" in result.stdout


def test_release_passes_final_notes_before_publication_without_a_later_edit(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    publisher = repo / "scripts" / "publish_release.sh"
    publisher.write_text('#!/bin/bash\nprintf "%s\\n" "$@" > "$(dirname "$0")/../publisher-call.txt"\n')
    publisher.chmod(0o755)
    _git(repo, "add", "scripts/publish_release.sh")
    _git(repo, *_IDENTITY, "commit", "-qm", "publisher double")
    result = _release(repo, _env(tmp_path))
    assert result.returncode == 0, result.stderr
    assert (repo / "publisher-call.txt").read_text().splitlines() == [
        "--notes-file", "dist/release-notes-1.2.3.md",
    ]


def test_an_unreleased_changelog_is_refused(tmp_path: Path) -> None:
    repo = _repo(tmp_path, changelog_top="## 1.2.3 (unreleased)")
    result = _dry_run(repo, tmp_path)
    assert result.returncode == 1 and "unreleased" in result.stderr


def test_a_changelog_for_another_version_is_refused(tmp_path: Path) -> None:
    repo = _repo(tmp_path, changelog_top="## 1.2.4")
    result = _dry_run(repo, tmp_path)
    assert result.returncode == 1 and "not '## 1.2.3'" in result.stderr


def test_a_dirty_tree_is_refused(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    (repo / "stray.txt").write_text("x")
    result = _dry_run(repo, tmp_path)
    assert result.returncode == 1 and "dirty" in result.stderr


@pytest.mark.parametrize("existing", ["v1.2.3"])
def test_an_existing_tag_is_refused(tmp_path: Path, existing: str) -> None:
    repo = _repo(tmp_path)
    _git(repo, "tag", existing)
    result = _dry_run(repo, tmp_path)
    assert result.returncode == 1 and "already exists" in result.stderr


def test_a_build_that_does_not_go_up_is_refused(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    _git(repo, "tag", "v1.2.2")  # the last release, at the same commit
    result = _dry_run(repo, tmp_path)
    assert result.returncode == 1 and "not higher" in result.stderr


def test_make_release_runs_the_checked_release_script() -> None:
    makefile = (ROOT / "Makefile").read_text()

    release = makefile.split("\nrelease:\n", 1)[1].split("\n\n", 1)[0]
    check = makefile.split("\nrelease-check:\n", 1)[1].split("\n\n", 1)[0]

    # The publisher alone skips the CHANGELOG and notes gates release.sh owns.
    assert release.strip() == "./scripts/release.sh"
    assert check.strip() == "./scripts/release.sh --dry-run"


@pytest.mark.parametrize("arguments", [[""], ["--dry-run", "extra"], ["--publish"]])
def test_an_empty_or_unknown_argument_is_a_usage_error(tmp_path: Path, arguments: list[str]) -> None:
    repo = _repo(tmp_path)

    result = _release(repo, _env(tmp_path), *arguments)

    assert result.returncode == 2, result.stderr
    assert "Usage" in result.stderr
    # It stopped before it wrote anything, and it did not publish.
    assert not (repo / "dist").exists()


def test_help_prints_the_header_and_touches_nothing(tmp_path: Path) -> None:
    repo = _repo(tmp_path)

    result = _release(repo, _env(tmp_path), "--help")

    assert result.returncode == 0
    assert "release.sh --dry-run" in result.stdout
    assert not (repo / "dist").exists()


def test_a_branch_other_than_main_is_refused(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    _git(repo, "checkout", "-q", "-b", "topic")

    result = _dry_run(repo, tmp_path)

    assert result.returncode == 1
    assert "main" in result.stderr and "topic" in result.stderr


def test_a_missing_gh_is_refused(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    # Only what release.sh itself runs, and no gh.
    tools = tmp_path / "tools"
    tools.mkdir()
    for name in ("bash", "git", "sed", "grep", "awk", "wc", "tr", "head", "mkdir", "dirname"):
        found = shutil.which(name)
        assert found, f"{name} is needed to run release.sh"
        (tools / name).symlink_to(found)

    result = _release(repo, _env(tmp_path, path=str(tools)), "--dry-run")

    assert result.returncode == 1
    assert "gh" in result.stderr


def test_a_head_that_is_not_origin_main_is_refused(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    origin = tmp_path / "origin.git"
    subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(origin)], check=True, capture_output=True, timeout=30)
    _git(repo, "remote", "add", "origin", str(origin))
    _git(repo, "push", "-q", "origin", "main")
    (repo / "later.txt").write_text("a change that was never pushed\n")
    _git(repo, "add", "later.txt")
    _git(repo, *_IDENTITY, "commit", "-qm", "two")
    env = _env(tmp_path, skip_remote=False)

    unpushed = _release(repo, env, "--dry-run")

    assert unpushed.returncode == 1
    assert "origin/main" in unpushed.stderr

    # The check reads origin's tip with ls-remote: pushing is enough, and no fetch ran.
    _git(repo, "push", "-q", "origin", "main")
    pushed = _release(repo, env, "--dry-run")
    assert pushed.returncode == 0, pushed.stderr
