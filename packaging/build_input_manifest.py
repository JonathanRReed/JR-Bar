#!/usr/bin/env python3
"""Bind a local package build to its tracked and untracked source inputs."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import subprocess
from pathlib import Path

PROTECTED = (".git", "app", "src", "hook", "packaging", "scripts", "requirements")
BUILD_OUTPUTS = ("build", "dist", "app/.build", "app/build", "hook/build")


def git_paths(root: Path) -> list[str]:
    top = subprocess.check_output(["git", "-C", str(root), "rev-parse", "--show-toplevel"]).strip()
    if Path(os.fsdecode(top)).resolve() != root:
        raise ValueError("ROOT must be the repository root")
    raw = subprocess.check_output([
        "git", "-C", str(root), "ls-files", "--cached", "--others", "--exclude-standard", "-z",
    ])
    return [os.fsdecode(name) for name in sorted(set(raw.split(b"\0")) - {b""})]


def within(path: Path, parent: Path) -> bool:
    return path == parent or parent in path.parents


def exclusions(root: Path, values: list[str], paths: list[str]) -> list[Path]:
    result = []
    for value in values:
        candidate = Path(value)
        absolute = (candidate if candidate.is_absolute() else root / candidate).resolve()
        if within(root, absolute):
            raise ValueError(f"Exclusion contains the source root: {value}")
        if within(absolute, root):
            allowed_output = any(within(absolute, root / name) for name in BUILD_OUTPUTS)
            if not allowed_output and any(within(absolute, root / name) or within(root / name, absolute)
                                          for name in PROTECTED):
                raise ValueError(f"Exclusion overlaps source inputs: {value}")
            if any(within(root / name, absolute) for name in paths):
                # Even a path named build may contain real tracked inputs.
                tracked = subprocess.check_output(["git", "-C", str(root), "ls-files", "-z"])
                if any(within(root / os.fsdecode(name), absolute) for name in tracked.split(b"\0") if name):
                    raise ValueError(f"Exclusion contains tracked inputs: {value}")
            result.append(absolute)
        else:
            result.append(absolute)
    return sorted(set(result), key=str)


def deleted_inputs(root: Path) -> list[str]:
    tracked = subprocess.check_output(["git", "-C", str(root), "ls-files", "-z"])
    deleted = []
    for raw in sorted(set(tracked.split(b"\0")) - {b""}):
        name = os.fsdecode(raw)
        path = root / name
        if not within(path.resolve(), root):
            raise ValueError(f"Source input resolves outside ROOT: {name}")
        try:
            path.lstat()
        except FileNotFoundError:
            for parent in path.parents:
                if parent == root:
                    break
                if parent.is_symlink():
                    parent.resolve(strict=True)
            deleted.append(name)
    return deleted


def recorded_deletions(value: object) -> list[str]:
    if not isinstance(value, list) or any(
        not isinstance(name, str) or not name or Path(name).is_absolute()
        or any(part in ("", ".", "..") for part in name.split("/")) for name in value
    ):
        raise ValueError("Malformed deleted_inputs")
    if value != sorted(set(value)):
        raise ValueError("Malformed deleted_inputs")
    return value


def inventory(root: Path, excluded: list[Path], receipt: Path, deleted: list[str] | None = None) -> dict[str, dict]:
    result = {}
    for name in git_paths(root):
        if deleted and name in deleted:
            continue
        path = root / name
        if path == receipt or any(within(path, directory) for directory in excluded):
            continue
        if not within(path.resolve(strict=True), root):
            raise ValueError(f"Source input resolves outside ROOT: {name}")
        metadata = path.lstat()
        mode = metadata.st_mode
        entry = {"executable": bool(mode & 0o111)}
        if stat.S_ISLNK(mode):
            resolved = path.resolve(strict=True)
            if not within(resolved, root) or not resolved.is_file():
                raise ValueError(f"Source symlink must resolve to a file inside ROOT: {name}")
            entry.update(kind="symlink", target=os.readlink(path),
                         sha256=hashlib.sha256(resolved.read_bytes()).hexdigest(),
                         target_executable=bool(resolved.stat().st_mode & 0o111))
        elif stat.S_ISREG(mode):
            entry.update(kind="file", sha256=hashlib.sha256(path.read_bytes()).hexdigest())
        else:
            raise ValueError(f"Unsupported source entry: {name}")
        result[name] = entry
    return result


def capture(root: Path, receipt: Path, excluded_values: list[str], *, allow_deleted: bool = False) -> None:
    root = root.resolve(strict=True)
    if receipt.is_symlink():
        raise ValueError("Receipt must not be a symlink")
    receipt = receipt.resolve()
    paths = git_paths(root)
    excluded = exclusions(root, excluded_values, paths)
    if within(receipt, root) and any(within(receipt, root / name) for name in PROTECTED):
        raise ValueError("Receipt must be outside protected source directories")
    deleted = deleted_inputs(root) if allow_deleted else []
    document = {"schema": 1, "root": str(root), "excluded": [str(path) for path in excluded],
                "inputs": inventory(root, excluded, receipt, deleted)}
    if allow_deleted:
        document["deleted_inputs"] = deleted
    receipt.parent.mkdir(parents=True, exist_ok=True)
    receipt.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")


def verify(root: Path, receipt: Path) -> None:
    root = root.resolve(strict=True)
    if receipt.is_symlink():
        raise ValueError("Receipt must not be a symlink")
    receipt = receipt.resolve()
    document = json.loads(receipt.read_text())
    if document.get("schema") != 1 or document.get("root") != str(root):
        raise ValueError("Manifest does not match ROOT")
    excluded = exclusions(root, document["excluded"], git_paths(root))
    deleted = recorded_deletions(document["deleted_inputs"]) if "deleted_inputs" in document else []
    if "deleted_inputs" in document and deleted_inputs(root) != deleted:
        raise ValueError("Deleted inputs changed")
    if any(name in document["inputs"] for name in deleted):
        raise ValueError("Malformed deleted_inputs: also present in inputs")
    current = inventory(root, excluded, receipt, deleted)
    before = document["inputs"]
    changed = sorted(name for name in set(before) | set(current) if before.get(name) != current.get(name))
    if changed:
        raise ValueError("Build inputs changed: " + ", ".join(changed))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for command in ("capture", "verify", "validate"):
        child = sub.add_parser(command)
        child.add_argument("root", type=Path)
        if command != "validate":
            child.add_argument("receipt", type=Path)
        if command == "capture":
            child.add_argument("--allow-deleted", action="store_true")
        if command in ("capture", "validate"):
            child.add_argument("--exclude", action="append", default=[])
    args = parser.parse_args()
    try:
        if args.command == "validate":
            root = args.root.resolve(strict=True)
            exclusions(root, args.exclude, git_paths(root))
        elif args.command == "capture":
            capture(args.root, args.receipt, args.exclude, allow_deleted=args.allow_deleted)
        else:
            verify(args.root, args.receipt)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Build input verification failed: {error}\n")


if __name__ == "__main__":
    main()
