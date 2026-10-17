"""Remove installation-origin metadata from a staged frozen daemon."""

import argparse
import os
from pathlib import Path


def strip_build_origin(core_app: Path) -> int:
    """Validate the staged resource tree, then unlink only direct_url.json files."""
    core_app = Path(core_app)
    contents = core_app / "Contents"
    resources = contents / "Resources"
    for directory in (core_app, contents, resources):
        if directory.is_symlink() or not directory.is_dir():
            raise ValueError("Expected real staged core resource directories")
    root = core_app.resolve(strict=True)
    if not resources.resolve(strict=True).is_relative_to(root):
        raise ValueError("Staged resources escape the core bundle")

    def walk_error(error: OSError) -> None:
        raise error

    origins = []
    for directory, directories, files in os.walk(resources, followlinks=False, onerror=walk_error):
        parent = Path(directory)
        for name in directories:
            child = parent / name
            if child.is_symlink() and not child.resolve(strict=True).is_relative_to(root):
                raise ValueError("Directory symlink escapes the staged core bundle")
        if parent.name.endswith(".dist-info") and "direct_url.json" in files:
            origins.append(parent / "direct_url.json")
    for origin in origins:
        origin.unlink()
    return len(origins)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--core-app", type=Path, required=True)
    args = parser.parse_args()
    try:
        count = strip_build_origin(args.core_app)
    except (OSError, ValueError):
        parser.exit(1, "Cannot strip installation-origin metadata from staged core resources.\n")
    print(f"Removed {count} installation-origin metadata files.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
