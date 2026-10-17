#!/usr/bin/env python3
"""Write a deterministic SHA-256 manifest for exact release artifacts."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import tempfile
from collections.abc import Iterable
from pathlib import Path


class ChecksumManifestError(RuntimeError):
    """Raised when an exact release checksum manifest cannot be written."""


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _artifact_record(path: Path, *, root: Path) -> tuple[str, Path]:
    candidate = path if path.is_absolute() else root / path
    try:
        resolved = candidate.resolve(strict=True)
    except FileNotFoundError:
        raise ChecksumManifestError(f"release artifact is missing: {candidate}") from None
    if not resolved.is_file():
        raise ChecksumManifestError(f"release artifact is not a file: {candidate}")
    try:
        relative = resolved.relative_to(root)
    except ValueError:
        raise ChecksumManifestError(f"release artifact is outside the release root: {candidate}") from None
    return relative.as_posix(), resolved


def checksum_manifest_text(*, root: Path, artifacts: Iterable[Path]) -> str:
    resolved_root = root.resolve(strict=True)
    records: dict[str, Path] = {}
    for artifact in artifacts:
        relative, resolved = _artifact_record(Path(artifact), root=resolved_root)
        if relative in records:
            raise ChecksumManifestError(f"duplicate release artifact: {relative}")
        records[relative] = resolved
    if not records:
        raise ChecksumManifestError("at least one release artifact is required")

    lines: list[str] = []
    for relative in sorted(records):
        lines.append(f"{_sha256_file(records[relative])}  {relative}")
    return "\n".join(lines) + "\n"


def _validate_evidence_manifest(
    *,
    root: Path,
    manifest: Path,
    artifacts: tuple[Path, ...],
) -> None:
    manifest_relative, manifest_path = _artifact_record(manifest, root=root)
    artifact_records = {
        relative: path for relative, path in (_artifact_record(artifact, root=root) for artifact in artifacts)
    }
    if manifest_relative not in artifact_records:
        raise ChecksumManifestError("release evidence manifest must be checksummed")
    try:
        document = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ChecksumManifestError(f"release evidence manifest is invalid: {exc}") from None
    if not isinstance(document, dict) or document.get("document") != "jr-bar-release-evidence":
        raise ChecksumManifestError("release evidence manifest has the wrong document type")
    raw_records = document.get("artifacts")
    if not isinstance(raw_records, list) or not raw_records:
        raise ChecksumManifestError("release evidence manifest has no artifacts")

    expected: dict[str, tuple[int, str]] = {}
    for index, record in enumerate(raw_records):
        if not isinstance(record, dict):
            raise ChecksumManifestError(f"release evidence artifact {index} is not an object")
        path = record.get("path")
        size = record.get("bytes")
        digest = record.get("sha256")
        if (
            not isinstance(path, str)
            or not path
            or type(size) is not int
            or size < 0
            or not isinstance(digest, str)
            or len(digest) != 64
            or any(character not in "0123456789abcdef" for character in digest)
        ):
            raise ChecksumManifestError(f"release evidence artifact {index} is malformed")
        if path in expected:
            raise ChecksumManifestError(f"release evidence repeats artifact: {path}")
        expected[path] = (size, digest)

    actual = {relative: path for relative, path in artifact_records.items() if relative != manifest_relative}
    if set(actual) != set(expected):
        raise ChecksumManifestError("release assets do not match the release evidence inventory")
    for relative, path in actual.items():
        expected_size, expected_digest = expected[relative]
        if path.stat().st_size != expected_size or _sha256_file(path) != expected_digest:
            raise ChecksumManifestError(f"release asset does not match release evidence: {relative}")
    _validate_sbom_binding(document, root=root, artifacts=tuple(actual.values()))


def _validate_sbom_binding(document: dict, *, root: Path, artifacts: tuple[Path, ...]) -> None:
    if __package__:
        from . import release_evidence
    else:
        import release_evidence

    try:
        candidate = document.get("candidate")
        if not isinstance(candidate, dict):
            raise ValueError("candidate identity is missing")
        paths = {}
        for name in ("sbom", "performance_evidence"):
            record = document.get(name)
            if not isinstance(record, dict) or not isinstance(record.get("path"), str):
                raise ValueError(f"{name} record is missing")
            _, path = _artifact_record(Path(record["path"]), root=root)
            if release_evidence.artifact_record(path, root=root) != record:
                raise ValueError(f"{name} no longer matches its evidence")
            if name == "sbom" and record not in document["artifacts"]:
                raise ValueError("SBOM is absent from the release artifact inventory")
            paths[name] = path
        release_evidence.validate_sbom_evidence(
            root=root,
            candidate=candidate,
            sbom=paths["sbom"],
            artifacts=artifacts,
            performance_evidence=paths["performance_evidence"],
        )
    except (OSError, ValueError, ChecksumManifestError) as exc:
        raise ChecksumManifestError(f"SBOM validation failed: {exc}") from exc


def write_checksum_manifest(
    *,
    root: Path,
    output: Path,
    artifacts: Iterable[Path],
    evidence_manifest: Path | None = None,
) -> Path:
    resolved_root = root.resolve(strict=True)
    artifact_paths = tuple(Path(path) for path in artifacts)
    resolved_output = output if output.is_absolute() else resolved_root / output
    resolved_output_parent = resolved_output.parent.resolve(strict=True)
    try:
        resolved_output_parent.relative_to(resolved_root)
    except ValueError:
        raise ChecksumManifestError(f"checksum output is outside the release root: {resolved_output}") from None
    text = checksum_manifest_text(root=resolved_root, artifacts=artifact_paths)
    if resolved_output.resolve(strict=False) in {
        (path if path.is_absolute() else resolved_root / path).resolve(strict=False) for path in artifact_paths
    }:
        raise ChecksumManifestError("checksum output cannot also be an input artifact")
    if evidence_manifest is not None:
        _validate_evidence_manifest(
            root=resolved_root,
            manifest=evidence_manifest,
            artifacts=artifact_paths,
        )

    temporary_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=resolved_output_parent,
            prefix=f".{resolved_output.name}.",
            delete=False,
        ) as temporary:
            temporary_name = temporary.name
            temporary.write(text)
            temporary.flush()
            os.fsync(temporary.fileno())
            os.fchmod(temporary.fileno(), 0o644)
        Path(temporary_name).replace(resolved_output)
    finally:
        if temporary_name is not None:
            Path(temporary_name).unlink(missing_ok=True)
    return resolved_output


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--evidence-manifest", type=Path)
    parser.add_argument("artifacts", nargs="+")
    args = parser.parse_args()
    try:
        output = write_checksum_manifest(
            root=args.root,
            output=args.output,
            artifacts=tuple(Path(path) for path in args.artifacts),
            evidence_manifest=args.evidence_manifest,
        )
    except (ChecksumManifestError, FileNotFoundError) as exc:
        print(f"release checksum generation failed: {exc}", file=sys.stderr)
        return 2
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
