#!/usr/bin/env python3
"""Inventory a JR-Bar build environment and bind its release artifacts."""

from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import os
import platform
import re
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

if __package__:
    from .release_evidence import sha256_tree
else:
    from release_evidence import sha256_tree

_NAME = re.compile(r"[-_.]+")


def _normalized_name(value: str) -> str:
    return _NAME.sub("-", value).casefold()


def _timestamp() -> str:
    raw = os.environ.get("SOURCE_DATE_EPOCH")
    if raw:
        try:
            moment = datetime.fromtimestamp(int(raw), timezone.utc)
        except (OSError, OverflowError, ValueError):
            raise ValueError("SOURCE_DATE_EPOCH must be a valid Unix timestamp") from None
    else:
        moment = datetime.now(timezone.utc)
    return moment.replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _relative_artifact_path(path: Path, *, root: Path) -> str:
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError as exc:
        raise ValueError(f"artifact is outside release root: {path}") from exc


def _license(metadata) -> list[dict[str, object]]:
    expression = metadata.get("License-Expression")
    if isinstance(expression, str) and expression.strip():
        return [{"expression": expression.strip()}]
    value = metadata.get("License")
    if isinstance(value, str) and value.strip() and value.strip() != "UNKNOWN":
        return [{"license": {"name": value.strip()[:256]}}]
    return []


def _component(distribution) -> dict[str, object] | None:
    metadata = distribution.metadata
    name = metadata.get("Name")
    version = distribution.version
    if not isinstance(name, str) or not name.strip() or not version:
        return None
    normalized = _normalized_name(name)
    component: dict[str, object] = {
        "type": "library",
        "name": name.strip(),
        "version": str(version),
        "bom-ref": f"pkg:pypi/{normalized}@{version}",
        "purl": f"pkg:pypi/{normalized}@{version}",
        "properties": [{"name": "jrbar:scope", "value": "build-environment"}],
    }
    licenses = _license(metadata)
    if licenses:
        component["licenses"] = licenses
    homepage = metadata.get("Home-page")
    if isinstance(homepage, str) and homepage.startswith(("https://", "http://")):
        component["externalReferences"] = [
            {"type": "website", "url": homepage[:2048]}
        ]
    return component


def build_sbom(
    *,
    application_version: str,
    artifacts: tuple[Path, ...] = (),
    root: Path | None = None,
    app: Path | None = None,
) -> dict[str, object]:
    components_by_ref: dict[str, dict[str, object]] = {}
    for distribution in importlib.metadata.distributions():
        component = _component(distribution)
        if component is not None:
            components_by_ref[str(component["bom-ref"])] = component
    components = [components_by_ref[key] for key in sorted(components_by_ref)]

    artifact_properties = []
    artifact_root = (root or Path.cwd()).resolve()
    for artifact in sorted(artifacts, key=lambda item: _relative_artifact_path(item, root=artifact_root)):
        relative_path = _relative_artifact_path(artifact, root=artifact_root)
        artifact_properties.extend(
            (
                {
                    "name": f"jrbar:artifact:{relative_path}:sha256",
                    "value": _sha256(artifact),
                },
                {
                    "name": f"jrbar:artifact:{relative_path}:bytes",
                    "value": str(artifact.stat().st_size),
                },
            )
        )

    if app is not None:
        artifact_properties.append({"name": "jrbar:app:sha256", "value": sha256_tree(app)})

    application_ref = f"pkg:github/JonathanRReed/JR-Bar@{application_version}"
    document = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "version": 1,
        "metadata": {
            "timestamp": _timestamp(),
            "lifecycles": [{"phase": "build"}],
            "tools": {
                "components": [
                    {
                        "type": "application",
                        "name": "JR-Bar SBOM Generator",
                        "version": "3",
                    }
                ]
            },
            "component": {
                "type": "application",
                "name": "JR-Bar",
                "version": application_version,
                "bom-ref": application_ref,
                "description": (
                    "Installed Python distributions in the build environment. "
                    "Bundled runtime dependencies, native libraries and the full dependency graph "
                    "are not established by this inventory."
                ),
                "properties": [
                    {"name": "jrbar:python", "value": platform.python_version()},
                    {"name": "jrbar:platform", "value": platform.platform()},
                    *artifact_properties,
                ],
            },
        },
        "components": components,
        "compositions": [{"aggregate": "incomplete", "assemblies": [application_ref]}],
    }
    identity = json.dumps(document, sort_keys=True, separators=(",", ":"))
    serial = uuid.uuid5(uuid.NAMESPACE_URL, f"https://github.com/JonathanRReed/JR-Bar/sbom/{identity}")
    document["serialNumber"] = f"urn:uuid:{serial}"
    return document


def _properties(component: dict) -> dict[str, str]:
    properties = component.get("properties", [])
    if not isinstance(properties, list):
        raise ValueError("component properties must be a list")
    result: dict[str, str] = {}
    for item in properties:
        if (not isinstance(item, dict) or not isinstance(item.get("name"), str)
                or not item["name"] or not isinstance(item.get("value"), str)):
            raise ValueError("invalid component property")
        if item["name"] in result:
            raise ValueError(f"duplicate property name: {item['name']}")
        result[item["name"]] = item["value"]
    return result


def validate_sbom(
    document, *, application_version: str, app: Path,
    artifacts: tuple[Path, ...], root: Path,
) -> None:
    if not isinstance(document, dict):
        raise ValueError("SBOM must be an object")
    if (document.get("bomFormat") != "CycloneDX" or document.get("specVersion") != "1.5"
            or type(document.get("version")) is not int or document["version"] != 1):
        raise ValueError("unsupported SBOM format or schema version")
    metadata = document.get("metadata")
    if not isinstance(metadata, dict) or metadata.get("lifecycles") != [{"phase": "build"}]:
        raise ValueError("SBOM must describe the build lifecycle")
    application = metadata.get("component")
    application_ref = f"pkg:github/JonathanRReed/JR-Bar@{application_version}"
    if (not isinstance(application, dict) or application.get("type") != "application"
            or application.get("name") != "JR-Bar" or not application_version
            or application.get("version") != application_version
            or application.get("bom-ref") != application_ref):
        raise ValueError("SBOM application identity does not match the candidate")
    properties = _properties(application)
    if properties.get("jrbar:app:sha256") != sha256_tree(app):
        raise ValueError("SBOM app tree hash does not match the candidate")
    expected_artifacts: dict[str, str] = {}
    for artifact in artifacts:
        relative = _relative_artifact_path(artifact, root=root)
        if not artifact.is_file():
            raise ValueError(f"artifact is not a file: {relative}")
        prefix = f"jrbar:artifact:{relative}"
        expected_artifacts[f"{prefix}:sha256"] = _sha256(artifact)
        expected_artifacts[f"{prefix}:bytes"] = str(artifact.stat().st_size)
    actual_artifacts = {k: v for k, v in properties.items() if k.startswith("jrbar:artifact:")}
    if actual_artifacts != expected_artifacts:
        raise ValueError("SBOM artifact paths, hashes or sizes do not match the candidate")
    if document.get("compositions") != [{"aggregate": "incomplete", "assemblies": [application_ref]}]:
        raise ValueError("SBOM coverage must remain incomplete")
    if "dependencies" in document:
        raise ValueError("this inventory does not establish a dependency graph")
    components = document.get("components")
    if not isinstance(components, list):
        raise ValueError("SBOM components must be a list")
    refs = {application_ref}
    for component in components:
        if (not isinstance(component, dict) or component.get("type") != "library"
                or any(not isinstance(component.get(key), str) or not component[key]
                       for key in ("name", "version", "bom-ref", "purl"))):
            raise ValueError("invalid build environment component")
        ref = component["bom-ref"]
        expected_ref = f"pkg:pypi/{_normalized_name(component['name'])}@{component['version']}"
        if ref in refs or ref != expected_ref or component["purl"] != ref:
            raise ValueError("invalid or duplicate component reference")
        refs.add(ref)
        if _properties(component).get("jrbar:scope") != "build-environment":
            raise ValueError("component scope must be build-environment")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--validate", type=Path)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--application-version", required=True)
    parser.add_argument("--artifact", action="append", type=Path, default=[])
    args = parser.parse_args()
    if args.validate is None and args.output is None:
        parser.error("--output is required for generation")
    if args.validate is not None and args.app is None:
        parser.error("--app is required for validation")
    try:
        artifacts = tuple(path.resolve() for path in args.artifact)
        missing = [str(path) for path in artifacts if not path.is_file()]
        if missing:
            raise FileNotFoundError(", ".join(missing))
        if args.validate is not None:
            document = json.loads(args.validate.read_text(encoding="utf-8"))
            validate_sbom(document, application_version=args.application_version, app=args.app,
                          artifacts=artifacts, root=args.root)
            print(f"SBOM validated: {args.validate}")
            return 0
        document = build_sbom(
            application_version=str(args.application_version),
            artifacts=artifacts,
            root=args.root.resolve(),
            app=args.app,
        )
        if args.app is not None:
            validate_sbom(document, application_version=args.application_version, app=args.app,
                          artifacts=artifacts, root=args.root)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(
            json.dumps(document, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    except (OSError, ValueError, importlib.metadata.PackageNotFoundError) as exc:
        print(f"SBOM generation failed: {exc}", file=sys.stderr)
        return 1
    print(f"SBOM written: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
