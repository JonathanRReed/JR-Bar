"""Repository names shared by collection and projection."""
import re
from functools import lru_cache
from pathlib import Path


def project_name(cwd: str | None, *, common_dir: str | None = None) -> str | None:
    """Fold known worktree layouts, or a proven git common directory."""
    if common_dir:
        root = Path(common_dir).parent
        return root.name or None
    parts = str(cwd or "").strip().rstrip("/").split("/")
    for index, part in enumerate(parts):
        if part == ".t3" and parts[index + 1:index + 2] == ["worktrees"] and len(parts) > index + 2:
            return parts[index + 2]
        if part == ".worktrees" and index:
            return parts[index - 1]
        if part == ".claude" and parts[index + 1:index + 2] == ["worktrees"] and index:
            return parts[index - 1]
    tail = parts[-1]
    return tail if tail and not re.fullmatch(r"t3-.*|[0-9a-fA-F]{8,}", tail) else None


@lru_cache(maxsize=512)
def repository_project(cwd: str | None) -> str | None:
    """Resolve git metadata during collection, never while projecting views."""
    if not cwd:
        return None
    path = Path(cwd)
    for root in (path, *path.parents):
        git = root / ".git"
        try:
            if git.is_dir():
                return project_name(str(root))
            if git.is_file():
                with git.open() as stream:
                    pointer = stream.read(4096).strip()
                if pointer.startswith("gitdir: "):
                    directory = (root / pointer[8:]).resolve()
                    try:
                        with (directory / "commondir").open() as stream:
                            common = stream.read(4096).strip()
                    except FileNotFoundError:
                        return project_name(str(root))
                    return project_name(cwd, common_dir=str((directory / common).resolve()))
        except OSError:
            continue
    return project_name(cwd)
