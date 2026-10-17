#!/usr/bin/env python3
"""Describe evidence-backed shipped contributors without claiming runtime execution."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote

if __package__:
    from .release_evidence import sha256_tree
else:
    from release_evidence import sha256_tree

HEX = re.compile(r"[0-9a-f]{64}\Z")
SCOPE = "Shipped contributors supported by candidate evidence. Observed execution and a complete dependency graph are not established."
SPARKLE_INFO = "Contents/Frameworks/Sparkle.framework/Versions/B/Resources/Info.plist"


def _require(condition: object, message: str) -> None:
    if not condition:
        raise ValueError(message)


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _text(value: object, label: str) -> str:
    _require(isinstance(value, str) and bool(value), f"missing {label}")
    return value


def _version(value: object, label: str) -> str:
    value = _text(value, label)
    _require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+!-]*", value) is not None, f"invalid {label}")
    return value


def _hash(value: object, label: str) -> str:
    _require(isinstance(value, str) and HEX.fullmatch(value) is not None, f"invalid {label}")
    return value


def _relative(value: object) -> str:
    value = _text(value, "member path")
    path = Path(value)
    _require(not path.is_absolute() and ".." not in path.parts and "\\" not in value
             and not value.startswith("~") and ":" not in value, "unsafe member path")
    return path.as_posix()


def _module(value: object) -> str:
    value = _text(value, "module name")
    _require(all(part.isidentifier() for part in value.split(".")), "invalid module name")
    return value


def _json(data: bytes, label: str) -> dict:
    def pairs(items):
        result = {}
        for name, value in items:
            _require(name not in result, "duplicate JSON key")
            result[name] = value
        return result
    try:
        result = json.loads(data, object_pairs_hook=pairs)
    except (ValueError, UnicodeError) as error:
        raise ValueError(f"invalid {label}") from error
    _require(isinstance(result, dict), f"{label} must be an object")
    return result


@dataclass(frozen=True)
class RuntimeEvidence:
    app: Path
    proof_path: Path
    expected_proof_sha256: str
    inventory_path: Path
    python_identity_path: Path
    native_evidence_path: Path
    proof: dict
    inventory: dict
    python_identity: dict
    native_evidence: dict
    hashes: dict[str, str]


def _paths(evidence: RuntimeEvidence) -> dict[str, Path]:
    return {"proof": evidence.proof_path, "inventory": evidence.inventory_path,
            "python-identity": evidence.python_identity_path,
            "native-evidence": evidence.native_evidence_path}


def _documents(evidence: RuntimeEvidence) -> dict[str, dict]:
    return {"proof": evidence.proof, "inventory": evidence.inventory,
            "python-identity": evidence.python_identity, "native-evidence": evidence.native_evidence}


def _check_app(app: Path, inventory: dict, native: dict) -> None:
    candidate = inventory["candidate"]
    _require(sha256_tree(app) == candidate["app_tree_sha256"], "candidate app tree differs")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    _require(info.get("CFBundleIdentifier") == candidate["identifier"]
             and info.get("CFBundleShortVersionString") == candidate["version"]
             and info.get("CFBundleVersion") == candidate["build"], "candidate bundle identity differs")
    framework_path = app / SPARKLE_INFO
    _require(framework_path.resolve(strict=True).is_relative_to(app), "framework metadata escapes app")
    framework_data = framework_path.read_bytes()
    framework = plistlib.loads(framework_data)
    sparkle = native["sparkle"]
    _require(_sha(framework_data) == sparkle["metadata_sha256"]
             and framework.get("CFBundleName") == sparkle["name"] == "Sparkle"
             and framework.get("CFBundleShortVersionString") == sparkle["version"], "Sparkle metadata differs")


def _check_links_data(evidence: RuntimeEvidence) -> None:
    proof, inventory, python, native = (evidence.proof, evidence.inventory,
                                         evidence.python_identity, evidence.native_evidence)
    candidate = inventory["candidate"]
    app_hash = _hash(candidate["app_tree_sha256"], "app hash")
    _require(candidate["identifier"] == "com.jonathanreed.jrbar", "wrong application identifier")
    _version(candidate["version"], "application version")
    _require(isinstance(candidate["build"], str) and candidate["build"].isdigit(), "invalid build")
    _require(type(proof["candidate_build"]) is int and str(proof["candidate_build"]) == candidate["build"], "proof build differs")
    _require(proof["candidate_app_sha256"] == app_hash, "proof app differs")
    source_hash = _hash(proof["source_manifest_sha256"], "source manifest hash")
    source_name = Path(_text(proof["source_manifest"], "source manifest")).name
    source_records = [value for path, value in inventory["inputs"].items() if Path(path).name == source_name]
    _require(source_records and all(value == source_hash for value in source_records), "source manifest binding differs")
    for role, path in _paths(evidence).items():
        if role != "proof":
            _require(proof["inventory_artifacts"].get(path.name) == evidence.hashes[role], "proof evidence hash differs")
    _require(inventory["app_hash_before"] == inventory["app_hash_after"] == app_hash, "inventory candidate changed")
    _require(python["candidate"] == candidate
             and python["app_hash_before"] == python["app_hash_after"] == app_hash
             and python["initial_inventory_sha256"] == evidence.hashes["inventory"], "Python evidence cross-link differs")
    _require(native["candidate_app_sha256"] == app_hash
             and native["inventory_sha256"] == evidence.hashes["inventory"], "native evidence cross-link differs")
    _hash(native["sparkle"]["metadata_sha256"], "Sparkle metadata hash")
    _require(native["sparkle"]["name"] == "Sparkle", "unexpected framework identity")
    _version(native["sparkle"]["version"], "Sparkle version")


def _check_links(evidence: RuntimeEvidence) -> None:
    try:
        _check_links_data(evidence)
    except (KeyError, TypeError, AttributeError) as error:
        raise ValueError("malformed runtime proof or evidence") from error


def load_runtime_evidence(*, app: Path, proof_path: Path, expected_proof_sha256: str,
                          inventory_path: Path, python_identity_path: Path,
                          native_evidence_path: Path) -> RuntimeEvidence:
    """Bind externally trusted proof bytes and their evidence to the actual app."""
    _hash(expected_proof_sha256, "expected proof hash")
    app = Path(app)
    _require(not app.is_symlink(), "app root must not be a symlink")
    app = app.resolve(strict=True)
    paths = {"proof": Path(proof_path).resolve(strict=True),
             "inventory": Path(inventory_path).resolve(strict=True),
             "python-identity": Path(python_identity_path).resolve(strict=True),
             "native-evidence": Path(native_evidence_path).resolve(strict=True)}
    _require(len(set(paths.values())) == 4, "evidence paths must be distinct")
    data = {role: path.read_bytes() for role, path in paths.items()}
    hashes = {role: _sha(value) for role, value in data.items()}
    _require(hashes["proof"] == expected_proof_sha256, "proof hash differs from external pin")
    documents = {role: _json(value, role) for role, value in data.items()}
    evidence = RuntimeEvidence(app, paths["proof"], expected_proof_sha256,
                               paths["inventory"], paths["python-identity"], paths["native-evidence"],
                               documents["proof"], documents["inventory"], documents["python-identity"],
                               documents["native-evidence"], hashes)
    _check_links(evidence)
    _check_app(app, evidence.inventory, evidence.native_evidence)
    _check_unchanged(evidence)
    return evidence


def _check_unchanged(evidence: RuntimeEvidence) -> None:
    _require(evidence.hashes.keys() == _paths(evidence).keys(), "unexpected evidence hash role")
    _require(evidence.hashes["proof"] == evidence.expected_proof_sha256, "proof pin differs")
    for role, path in _paths(evidence).items():
        data = path.read_bytes()
        _require(_sha(data) == evidence.hashes[role]
                 and _json(data, role) == _documents(evidence)[role], "evidence changed")
    _check_links(evidence)
    _check_app(evidence.app, evidence.inventory, evidence.native_evidence)


def _properties(values: dict[str, object]) -> list[dict[str, str]]:
    return [{"name": name, "value": value if isinstance(value, str) else json.dumps(value, sort_keys=True, separators=(",", ":"))}
            for name, value in sorted(values.items())]


def _epoch(value: object) -> int:
    _require(type(value) is int and value >= 0, "source_date_epoch must be a nonnegative integer")
    try:
        datetime.fromtimestamp(value, timezone.utc)
    except (ValueError, OverflowError, OSError) as error:
        raise ValueError("source_date_epoch is out of range") from error
    return value


def _render(evidence: RuntimeEvidence, epoch: int) -> dict:
    epoch = _epoch(epoch)
    inventory, python, native = evidence.inventory, evidence.python_identity, evidence.native_evidence
    candidate = inventory["candidate"]
    root_ref = "urn:jrbar:app:" + candidate["app_tree_sha256"]
    components: dict[str, dict] = {}
    contributor_members: dict[str, dict[str, dict]] = {}
    input_hashes = dict(inventory["inputs"])
    for path, checksum in python["inputs"].items():
        _require(path not in input_hashes or input_hashes[path] == checksum, "evidence input identities conflict")
        input_hashes[path] = checksum

    def add_owner(owner: dict, member: dict) -> None:
        if owner.get("record_identity") != "matched":
            return
        name = _text(owner.get("distribution"), "distribution name")
        normalized = re.sub(r"[-_.]+", "-", name).lower()
        _require(re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", normalized) is not None, "invalid distribution name")
        if normalized == "jrbar":
            return
        version = _text(owner.get("version"), "distribution version")
        _require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+!-]*", version) is not None, "invalid distribution version")
        metadata_hash = _hash(input_hashes.get(owner.get("metadata")), "distribution metadata hash")
        record_hash = _hash(input_hashes.get(owner.get("record")), "distribution RECORD hash")
        _require(type(owner.get("vendor")) is bool, "missing vendor context")
        context = "setuptools-vendored" if owner["vendor"] else "distribution"
        identity = [normalized, version, context, metadata_hash, record_hash]
        ref = "urn:jrbar:contributor:" + _sha(json.dumps(identity, separators=(",", ":")).encode())
        if ref not in components:
            components[ref] = {"type": "library", "name": name, "version": version, "bom-ref": ref,
                               "purl": "pkg:pypi/" + normalized + "@" + quote(version, safe=".~-"),
                               "properties": _properties({"jrbar:scope": "shipped-record-claimed-contributor",
                                   "jrbar:vendor-context": context, "jrbar:metadata:sha256": metadata_hash,
                                   "jrbar:record:sha256": record_hash})}
            contributor_members[ref] = {}
        supporting_member = dict(member)
        if supporting_member["identity"] == "semantic-code":
            supporting_member["identity"] = "semantic-code-and-source-RECORD"
        key = json.dumps(supporting_member, sort_keys=True, separators=(",", ":"))
        contributor_members[ref][key] = supporting_member

    def code_member(row: dict, *, enrichment=False) -> dict:
        container = row["container"]
        _require(container in {"PYZ", "CArchive"}, "unknown code container")
        return {"container": container, "module": _module(row["member"] if enrichment else row["name"]),
                "sha256": _hash(row["member_sha256"] if enrichment else row["sha256"], "code member hash"),
                "identity": "semantic-code"}

    stdlib_members = {}
    for row in inventory["python_members"]:
        if row["mapping_status"] != "verified-code":
            continue
        member = code_member(row)
        source = row.get("source") or {}
        for owner in source.get("owners", []):
            add_owner(owner, member)
        if row.get("owner_status") == "toolchain-source":
            stdlib_members[json.dumps(member, sort_keys=True)] = dict(member, source_sha256=_hash(source.get("sha256"), "stdlib source hash"))
    for row in python["carchive_source_identities"]:
        if row["status"] != "match":
            continue
        member = code_member(row, enrichment=True)
        for owner in row.get("owners", []):
            add_owner(owner, member)
        if row.get("source_identity", {}).get("kind") == "pinned-Python-toolchain-source":
            _require(row["source_identity"]["python"] == inventory["python"], "stdlib Python identity differs")
            stdlib_members[json.dumps(member, sort_keys=True)] = dict(member, source_sha256=_hash(row.get("source_sha256"), "stdlib source hash"))
    for row in python["base_library_members"]:
        if row["status"] == "match" and row.get("source_identity", {}).get("kind") == "pinned-Python-toolchain-source":
            _require(row["source_identity"]["python"] == inventory["python"], "stdlib Python identity differs")
            member = {"container": "base_library.zip", "member": _relative(row["member"]),
                      "sha256": _hash(row["member_sha256"], "base member hash"),
                      "source_sha256": _hash(row["source_sha256"], "stdlib source hash"), "identity": "semantic-code"}
            stdlib_members[json.dumps(member, sort_keys=True)] = member
    for row in inventory["native_members"]:
        member = {"path": _relative(row["path"]), "sha256": _hash(row["sha256"], "native member hash"),
                  "identity": "native-path-attribution-only"}
        for source in row.get("sources", []):
            if source:
                for owner in source.get("owners", []):
                    add_owner(owner, member)
    for ref, component in components.items():
        members = sorted(contributor_members[ref].values(), key=lambda member: json.dumps(member, sort_keys=True))
        component["properties"].extend(_properties({"jrbar:supporting-members": members,
                                                     "jrbar:supporting-member-count": len(members)}))
        component["properties"].sort(key=lambda prop: prop["name"])
    if stdlib_members:
        version = _text(inventory["python"], "Python version")
        _require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) is not None, "invalid Python version")
        members = sorted(stdlib_members.values(), key=lambda member: json.dumps(member, sort_keys=True))
        ref = "urn:jrbar:cpython-stdlib:" + version
        components[ref] = {"type": "library", "name": "CPython standard library", "version": version,
                           "bom-ref": ref, "properties": _properties({"jrbar:scope": "shipped-standard-library-source-contributor",
                               "jrbar:identity": "Pinned toolchain source matched to shipped Python code; no PyPI ownership or native runtime identity is implied.",
                               "jrbar:supporting-members": members, "jrbar:supporting-member-count": len(members)})}
    sparkle = native["sparkle"]
    sparkle_members = []
    for row in inventory["native_members"]:
        if row["path"].startswith("Contents/Frameworks/Sparkle.framework/"):
            sparkle_members.append({"path": _relative(row["path"]), "sha256": _hash(row["sha256"], "Sparkle member hash")})
    _require(sparkle_members, "no shipped Sparkle members")
    declared = []
    for edge in native["edges"]:
        if edge["status"] == "bundled-candidate":
            targets = [_relative(path) for path in edge.get("bundled_candidates", [])]
            if any(path.startswith("Contents/Frameworks/Sparkle.framework/") for path in targets):
                _require(edge["command"] in {"LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB", "LC_LOAD_UPWARD_DYLIB", "LC_LAZY_LOAD_DYLIB"}, "invalid declared load command")
                _require(edge["architecture"] in {"arm64", "arm64e", "x86_64", "x86_64h", "i386", "ppc", "ppc64"}, "invalid declared architecture")
                declared.append({"from": _relative(edge["from"]), "command": edge["command"],
                                 "architecture": edge["architecture"], "bundled_candidates": sorted(targets)})
    _require(declared, "no declared Sparkle bundled candidate")
    sparkle_ref = "urn:jrbar:sparkle:" + sparkle["metadata_sha256"]
    components[sparkle_ref] = {"type": "library", "name": "Sparkle", "version": sparkle["version"],
                               "bom-ref": sparkle_ref, "properties": _properties({"jrbar:scope": "shipped-framework-metadata-contributor",
                                   "jrbar:metadata:sha256": sparkle["metadata_sha256"],
                                   "jrbar:supporting-members": sorted(sparkle_members, key=lambda member: member["path"]),
                                   "jrbar:declared-native-links": sorted(declared, key=lambda edge: json.dumps(edge, sort_keys=True)),
                                   "jrbar:link-scope": "Declared bundled candidate; runtime selection was not observed."})}
    document = {"bomFormat": "CycloneDX", "specVersion": "1.5", "version": 1,
                "metadata": {"timestamp": datetime.fromtimestamp(epoch, timezone.utc).isoformat().replace("+00:00", "Z"),
                             "lifecycles": [{"phase": "post-build"}],
                             "tools": {"components": [{"type": "application", "name": "JR-Bar runtime contributor generator", "version": "1"}]},
                             "component": {"type": "application", "name": "JR-Bar", "version": candidate["version"],
                                           "bom-ref": root_ref, "description": SCOPE,
                                           "properties": _properties({"jrbar:scope": "shipped-contributors",
                                               "jrbar:build": candidate["build"], "jrbar:app:sha256": candidate["app_tree_sha256"],
                                               "jrbar:source-manifest:sha256": evidence.proof["source_manifest_sha256"],
                                               "jrbar:source-date-epoch": str(epoch),
                                               "jrbar:inventory-counts": {"files-and-links": len(inventory.get("files", [])),
                                                   "python-members": len(inventory["python_members"]),
                                                   "native-members": len(inventory["native_members"]),
                                                   "native-declarations": len(native["edges"])},
                                               **{"jrbar:evidence:" + role + ":sha256": value for role, value in evidence.hashes.items()},
                                               "jrbar:coverage": "Incomplete. RECORD claims can overlap. Native path attribution, unknown resources, dynamic loading and dependency edges remain qualified or unestablished."})}},
                "components": [components[key] for key in sorted(components)],
                "compositions": [{"aggregate": "incomplete", "assemblies": [root_ref]}]}
    serial_identity = json.dumps(document, sort_keys=True, separators=(",", ":"))
    document["serialNumber"] = "urn:uuid:" + str(uuid.uuid5(uuid.NAMESPACE_URL, serial_identity))
    return document


def build_runtime_sbom(*, evidence: RuntimeEvidence, source_date_epoch: int) -> dict:
    _check_unchanged(evidence)
    document = _render(evidence, source_date_epoch)
    _check_unchanged(evidence)
    return document


def validate_runtime_sbom(document: dict, *, evidence: RuntimeEvidence) -> None:
    """Require the exact proof-derived document, including scope and component membership."""
    try:
        properties = document["metadata"]["component"]["properties"]
        values = [prop["value"] for prop in properties if prop["name"] == "jrbar:source-date-epoch"]
        _require(len(values) == 1 and isinstance(values[0], str) and re.fullmatch(r"0|[1-9][0-9]*", values[0]) is not None, "invalid epoch property")
        expected = build_runtime_sbom(evidence=evidence, source_date_epoch=int(values[0]))
        _require(document == expected, "runtime contributor SBOM differs from evidence")
    except (KeyError, TypeError, OverflowError) as error:
        raise ValueError("malformed runtime contributor SBOM") from error


def _output_path(path: Path, evidence: RuntimeEvidence) -> Path:
    _require(not path.exists() and not path.is_symlink(), "output already exists")
    output = path.resolve(strict=False)
    forbidden = [evidence.app, *_paths(evidence).values()]
    _require(output not in forbidden and not output.is_relative_to(evidence.app), "output aliases immutable input")
    # Evidence source paths locate immutable roots. They are never emitted.
    protected = {Path(__file__).resolve().parents[1]}
    for name in evidence.inventory.get("inputs", {}):
        input_path = Path(name)
        _require(output != input_path.resolve(strict=False), "output aliases evidence input")
        protected.update(ancestor.resolve(strict=False) for ancestor in input_path.parents
                         if re.fullmatch(r"build[0-9]+(?:-source-.+)?", ancestor.name))
    _require(not any(output.is_relative_to(root) for root in protected), "output is inside immutable source or build root")
    return output


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--proof", type=Path, required=True)
    parser.add_argument("--expected-proof-sha256", required=True)
    parser.add_argument("--inventory", type=Path, required=True)
    parser.add_argument("--python-identity", type=Path, required=True)
    parser.add_argument("--native-evidence", type=Path, required=True)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--output", type=Path)
    mode.add_argument("--validate", type=Path)
    parser.add_argument("--source-date-epoch")
    args = parser.parse_args()
    try:
        evidence = load_runtime_evidence(app=args.app, proof_path=args.proof,
            expected_proof_sha256=args.expected_proof_sha256, inventory_path=args.inventory,
            python_identity_path=args.python_identity, native_evidence_path=args.native_evidence)
        if args.validate is not None:
            validate_runtime_sbom(_json(args.validate.read_bytes(), "runtime SBOM"), evidence=evidence)
            print("Runtime contributor SBOM matches the candidate evidence.")
            return 0
        raw_epoch = args.source_date_epoch if args.source_date_epoch is not None else os.environ.get("SOURCE_DATE_EPOCH")
        _require(isinstance(raw_epoch, str) and re.fullmatch(r"0|[1-9][0-9]*", raw_epoch) is not None, "explicit SOURCE_DATE_EPOCH or --source-date-epoch is required")
        output = _output_path(args.output, evidence)
        document = build_runtime_sbom(evidence=evidence, source_date_epoch=int(raw_epoch))
        validate_runtime_sbom(document, evidence=evidence)
        serialized = json.dumps(document, indent=2, sort_keys=True) + "\n"
        with output.open("x", encoding="utf-8") as handle:
            handle.write(serialized)
        print("Runtime contributor SBOM written with incomplete coverage.")
        return 0
    except (OSError, ValueError, KeyError, TypeError, OverflowError) as error:
        print(f"Runtime contributor SBOM rejected: {type(error).__name__}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
