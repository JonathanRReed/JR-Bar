"""Development commands keep the selected Python and worktree sources."""
from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def _run(root: Path, *arguments: str, python: str | None = None) -> subprocess.CompletedProcess[str]:
    env = {key: value for key, value in os.environ.items()
           if key not in {"PYTHON", "PYTHONPATH", "VENV_DIR", "JRBAR_DEV_VENV", "SIDEPULSE_DEV_VENV"}}
    if python is not None:
        env["PYTHON"] = python
    return subprocess.run(arguments, cwd=root, env=env, text=True,
                          capture_output=True, check=True, timeout=30)


def _setup(root: Path) -> None:
    (root / "scripts").mkdir(parents=True)
    shutil.copy2(ROOT / "scripts/python-env.sh", root / "scripts")
    shutil.copy2(ROOT / "Makefile", root)
    (root / "pyproject.toml").write_text('version = "1.0.0"\n')


def test_make_keeps_explicit_python_and_worktree_imports(tmp_path: Path) -> None:
    root = tmp_path / "source with spaces"
    _setup(root)
    python = tmp_path / "chosen python"
    python.write_text('#!/bin/sh\nprintf "%s\\n%s\\n%s\\n" "$0" "$PYTHON" "$PYTHONPATH"\n')
    python.chmod(0o755)
    result = _run(root, "make", "fast", python=str(python))
    assert result.stdout.splitlines()[-3:] == [str(python), str(python), str(root / "src")]
    assert not (root / ".venv").exists()


def test_worktree_uses_main_environment_without_symlink(tmp_path: Path) -> None:
    main = tmp_path / "main checkout"
    _setup(main)
    _run(main, "git", "init", "-q")
    worktree = tmp_path / "worktree"
    _run(main, "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
         "commit", "--allow-empty", "-m", "Initialize fixture")
    _run(main, "git", "worktree", "add", "--detach", str(worktree))
    _setup(worktree)
    python = main / ".venv/bin/python"
    python.parent.mkdir(parents=True)
    python.write_text('#!/bin/sh\nprintf "%s\\n%s\\n" "$0" "$PYTHONPATH"\n')
    python.chmod(0o755)
    result = _run(worktree, "make", "fast")
    assert result.stdout.splitlines()[-2:] == [str(python), str(worktree / "src")]
    assert not (worktree / ".venv").exists()
