from __future__ import annotations

import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


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

