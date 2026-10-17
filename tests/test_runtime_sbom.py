"""Synthetic contract tests for the evidence-bound runtime contributor SBOM."""

from __future__ import annotations

import copy
import hashlib
import json
import plistlib
import sys
from pathlib import Path

import pytest

from scripts import generate_runtime_sbom as runtime_sbom


def _json_bytes(value: dict) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


def _write_json(path: Path, value: dict) -> str:
    data = _json_bytes(value)
    path.write_bytes(data)
    return hashlib.sha256(data).hexdigest()


def _owner(name: str, *, vendor: bool, metadata: str, record: str,
           record_path: str = "sample.py", identity: str = "matched") -> dict:
    return {
        "distribution": name,
        "version": "1.2.3",
        "vendor": vendor,
        "metadata": metadata,
        "record": record,
        "record_path": record_path,
        "record_identity": identity,
    }


def _fixture(tmp_path: Path) -> dict:
    app = tmp_path / "JR-Bar.app"
    (app / "Contents/Frameworks/Sparkle.framework/Versions/B/Resources").mkdir(parents=True)
    (app / "Contents/Frameworks/Sparkle.framework/Versions/B").mkdir(exist_ok=True)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "com.jonathanreed.jrbar",
        "CFBundleShortVersionString": "0.9.17",
        "CFBundleVersion": "3289",
    }))
    sparkle_info = app / runtime_sbom.SPARKLE_INFO
    sparkle_info.write_bytes(plistlib.dumps({
        "CFBundleName": "Sparkle",
        "CFBundleShortVersionString": "2.9.4",
    }))
    sparkle_binary = app / "Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"
    sparkle_binary.write_bytes(b"synthetic Sparkle framework member")
    extension = app / "Contents/Helpers/jrbar-core.app/Contents/Frameworks/sample.so"
    extension.parent.mkdir(parents=True)
    extension.write_bytes(b"synthetic native extension")

    app_hash = runtime_sbom.sha256_tree(app)
    source_manifest_path = str(tmp_path / "release" / "source-manifest.json")
    source_manifest_hash = hashlib.sha256(b"synthetic frozen source manifest").hexdigest()
    alpha_metadata = str(tmp_path / "site-packages/alpha-1.2.3.dist-info/METADATA")
    alpha_record = str(tmp_path / "site-packages/alpha-1.2.3.dist-info/RECORD")
    vendor_metadata = str(tmp_path / "site-packages/setuptools/_vendor/alpha-1.2.3.dist-info/METADATA")
    vendor_record = str(tmp_path / "site-packages/setuptools/_vendor/alpha-1.2.3.dist-info/RECORD")
    build_metadata = str(tmp_path / "site-packages/build-only-9.0.dist-info/METADATA")
    build_record = str(tmp_path / "site-packages/build-only-9.0.dist-info/RECORD")
    metadata_hashes = {
        alpha_metadata: hashlib.sha256(b"alpha metadata").hexdigest(),
        alpha_record: hashlib.sha256(b"alpha record").hexdigest(),
        vendor_metadata: hashlib.sha256(b"vendor alpha metadata").hexdigest(),
        vendor_record: hashlib.sha256(b"vendor alpha record").hexdigest(),
        build_metadata: hashlib.sha256(b"build-only metadata").hexdigest(),
        build_record: hashlib.sha256(b"build-only record").hexdigest(),
    }
    inventory = {
        "candidate": {
            "build": "3289",
            "version": "0.9.17",
            "identifier": "com.jonathanreed.jrbar",
            "app_tree_sha256": app_hash,
        },
        "app_hash_before": app_hash,
        "app_hash_after": app_hash,
        "python": "3.12.13",
        "inputs": {source_manifest_path: source_manifest_hash, **metadata_hashes},
        "python_members": [
            {
                "container": "PYZ",
                "name": "alpha.module",
                "sha256": hashlib.sha256(b"alpha code").hexdigest(),
                "mapping_status": "verified-code",
                "owner_status": "mapped",
                "source": {"owners": [
                    _owner("Alpha_Pkg", vendor=False, metadata=alpha_metadata, record=alpha_record),
                    _owner("Alpha_Pkg", vendor=True, metadata=vendor_metadata, record=vendor_record),
                    _owner("BuildOnly", vendor=False, metadata=build_metadata, record=build_record,
                           identity="unmatched"),
                ]},
            },
        ],
        "native_members": [
            {
                "path": "Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle",
                "sha256": hashlib.sha256(sparkle_binary.read_bytes()).hexdigest(),
                "sources": [],
            },
            {
                "path": "Contents/Helpers/jrbar-core.app/Contents/Frameworks/sample.so",
                "sha256": hashlib.sha256(extension.read_bytes()).hexdigest(),
                "sources": [{"owners": [
                    _owner("Alpha_Pkg", vendor=True, metadata=vendor_metadata, record=vendor_record,
                           record_path="alpha_native.so"),
                ]}],
            },
        ],
    }
    python_identity = {
        "candidate": copy.deepcopy(inventory["candidate"]),
        "app_hash_before": app_hash,
        "app_hash_after": app_hash,
        "initial_inventory_sha256": hashlib.sha256(_json_bytes(inventory)).hexdigest(),
        "inputs": metadata_hashes,
        "base_library_members": [],
        "carchive_source_identities": [
            {
                "status": "match",
                "container": "CArchive",
                "member": "alpha.loader",
                "member_sha256": hashlib.sha256(b"loader code").hexdigest(),
                "owners": [_owner("Alpha_Pkg", vendor=False, metadata=alpha_metadata,
                                   record=alpha_record, record_path="alpha/loader.pyc")],
            },
        ],
    }
    sparkle_hash = hashlib.sha256(sparkle_info.read_bytes()).hexdigest()
    native_evidence = {
        "candidate_app_sha256": app_hash,
        "inventory_sha256": hashlib.sha256(_json_bytes(inventory)).hexdigest(),
        "sparkle": {"name": "Sparkle", "version": "2.9.4", "metadata_sha256": sparkle_hash},
        "edges": [{
            "status": "bundled-candidate",
            "from": "Contents/MacOS/JR-Bar",
            "command": "LC_LOAD_DYLIB",
            "architecture": "arm64",
            "bundled_candidates": ["Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"],
        }],
    }

    inventory_path = tmp_path / "inventory.json"
    python_path = tmp_path / "python-identity.json"
    native_path = tmp_path / "native-evidence.json"
    inventory_hash = _write_json(inventory_path, inventory)
    python_hash = _write_json(python_path, python_identity)
    native_hash = _write_json(native_path, native_evidence)
    proof = {
        "candidate_build": 3289,
        "candidate_app_sha256": app_hash,
        "source_manifest": source_manifest_path,
        "source_manifest_sha256": source_manifest_hash,
        "inventory_artifacts": {
            inventory_path.name: inventory_hash,
            python_path.name: python_hash,
            native_path.name: native_hash,
        },
    }
    proof_path = tmp_path / "proof.json"
    proof_hash = _write_json(proof_path, proof)
    evidence = runtime_sbom.load_runtime_evidence(
        app=app,
        proof_path=proof_path,
        expected_proof_sha256=proof_hash,
        inventory_path=inventory_path,
        python_identity_path=python_path,
        native_evidence_path=native_path,
    )
    return {
        "app": app,
        "proof_path": proof_path,
        "inventory_path": inventory_path,
        "python_path": python_path,
        "native_path": native_path,
        "proof": proof,
        "inventory": inventory,
        "python_identity": python_identity,
        "native_evidence": native_evidence,
        "evidence": evidence,
        "proof_hash": proof_hash,
        "source_manifest_path": source_manifest_path,
    }


def _load(fixture: dict, *, proof_hash: str | None = None):
    return runtime_sbom.load_runtime_evidence(
        app=fixture["app"],
        proof_path=fixture["proof_path"],
        expected_proof_sha256=proof_hash or fixture["proof_hash"],
        inventory_path=fixture["inventory_path"],
        python_identity_path=fixture["python_path"],
        native_evidence_path=fixture["native_path"],
    )


def test_load_binds_external_proof_three_evidence_hashes_and_real_app_metadata(tmp_path):
    fixture = _fixture(tmp_path)
    evidence = fixture["evidence"]
    assert evidence.hashes["proof"] == fixture["proof_hash"]
    assert evidence.hashes["inventory"] == fixture["proof"]["inventory_artifacts"]["inventory.json"]
    assert evidence.hashes["python-identity"] == fixture["proof"]["inventory_artifacts"]["python-identity.json"]
    assert evidence.hashes["native-evidence"] == fixture["proof"]["inventory_artifacts"]["native-evidence.json"]

    document = runtime_sbom.build_runtime_sbom(evidence=evidence, source_date_epoch=1_800_000_000)
    component = document["metadata"]["component"]
    properties = {item["name"]: item["value"] for item in component["properties"]}
    assert component["version"] == "0.9.17"
    assert properties["jrbar:build"] == "3289"
    assert properties["jrbar:app:sha256"] == fixture["inventory"]["candidate"]["app_tree_sha256"]
    assert properties["jrbar:source-manifest:sha256"] == fixture["proof"]["source_manifest_sha256"]
    for role, checksum in evidence.hashes.items():
        assert properties[f"jrbar:evidence:{role}:sha256"] == checksum


def test_external_proof_pin_is_exact(tmp_path):
    fixture = _fixture(tmp_path)
    fixture["proof_path"].write_bytes(fixture["proof_path"].read_bytes() + b"\n")
    with pytest.raises(ValueError, match="proof hash differs"):
        _load(fixture)


@pytest.mark.parametrize("role", ["inventory", "python-identity", "native-evidence"])
def test_each_evidence_document_must_match_its_proof_pin_and_crosslinks(tmp_path, role):
    fixture = _fixture(tmp_path)
    paths = {
        "inventory": fixture["inventory_path"],
        "python-identity": fixture["python_path"],
        "native-evidence": fixture["native_path"],
    }
    document = {
        "inventory": copy.deepcopy(fixture["inventory"]),
        "python-identity": copy.deepcopy(fixture["python_identity"]),
        "native-evidence": copy.deepcopy(fixture["native_evidence"]),
    }[role]
    if role == "inventory":
        document["candidate"]["build"] = "3290"
    elif role == "python-identity":
        document["initial_inventory_sha256"] = "0" * 64
    else:
        document["inventory_sha256"] = "0" * 64
    path = paths[role]
    new_hash = _write_json(path, document)
    fixture["proof"]["inventory_artifacts"][path.name] = new_hash
    fixture["proof_hash"] = _write_json(fixture["proof_path"], fixture["proof"])
    with pytest.raises(ValueError):
        _load(fixture)


def test_source_manifest_hash_must_match_inventory_input(tmp_path):
    fixture = _fixture(tmp_path)
    fixture["proof"]["source_manifest_sha256"] = "0" * 64
    fixture["proof_hash"] = _write_json(fixture["proof_path"], fixture["proof"])
    with pytest.raises(ValueError, match="source manifest binding differs"):
        _load(fixture)


def test_epoch_determinism_record_only_ownership_vendor_context_and_incomplete_scope(tmp_path):
    fixture = _fixture(tmp_path)
    evidence = fixture["evidence"]
    first = runtime_sbom.build_runtime_sbom(evidence=evidence, source_date_epoch=1_800_000_000)
    second = runtime_sbom.build_runtime_sbom(evidence=evidence, source_date_epoch=1_800_000_000)
    assert first == second
    assert first["metadata"]["timestamp"] == "2027-01-15T08:00:00Z"
    assert first["compositions"] == [{
        "aggregate": "incomplete",
        "assemblies": ["urn:jrbar:app:" + fixture["inventory"]["candidate"]["app_tree_sha256"]],
    }]
    assert "dependencies" not in first

    contributors = [component for component in first["components"]
                    if component["name"] == "Alpha_Pkg"]
    assert len(contributors) == 2, "same RECORD claimant in two vendor contexts keeps separate evidence"
    contexts = {next(prop["value"] for prop in component["properties"]
                     if prop["name"] == "jrbar:vendor-context") for component in contributors}
    assert contexts == {"distribution", "setuptools-vendored"}
    for component in contributors:
        properties = {prop["name"]: prop["value"] for prop in component["properties"]}
        assert properties["jrbar:scope"] == "shipped-record-claimed-contributor"
        assert properties["jrbar:record:sha256"]
        assert properties["jrbar:metadata:sha256"]
    assert not any(component["name"] == "BuildOnly" for component in first["components"])

    serialized = json.dumps(first, sort_keys=True)
    assert str(tmp_path) not in serialized, "private host paths must not enter the SBOM"
    runtime_sbom.validate_runtime_sbom(first, evidence=evidence)


@pytest.mark.parametrize("mutation", ["coverage", "dependency", "added", "removed", "scope"])
def test_tampered_output_is_rejected(tmp_path, mutation):
    fixture = _fixture(tmp_path)
    evidence = fixture["evidence"]
    document = runtime_sbom.build_runtime_sbom(evidence=evidence, source_date_epoch=1_800_000_000)
    tampered = copy.deepcopy(document)
    if mutation == "coverage":
        tampered["compositions"][0]["aggregate"] = "complete"
    elif mutation == "dependency":
        tampered["dependencies"] = []
    elif mutation == "added":
        tampered["components"].append({"type": "library", "name": "Invented"})
    elif mutation == "removed":
        tampered["components"].pop()
    else:
        tampered["metadata"]["component"]["properties"][0]["value"] = "complete runtime"
    with pytest.raises(ValueError):
        runtime_sbom.validate_runtime_sbom(tampered, evidence=evidence)


def test_output_guard_rejects_existing_app_and_input_aliases_without_changes(tmp_path):
    fixture = _fixture(tmp_path)
    evidence = fixture["evidence"]
    output = tmp_path / "result.json"
    assert runtime_sbom._output_path(output, evidence) == output

    existing = tmp_path / "existing.json"
    existing.write_bytes(b"keep these bytes")
    with pytest.raises(ValueError, match="output already exists"):
        runtime_sbom._output_path(existing, evidence)
    assert existing.read_bytes() == b"keep these bytes"

    with pytest.raises(ValueError, match="output aliases immutable input"):
        runtime_sbom._output_path(fixture["app"] / "extra.json", evidence)
    with pytest.raises(ValueError, match="output aliases evidence input"):
        runtime_sbom._output_path(Path(fixture["source_manifest_path"]), evidence)


@pytest.mark.parametrize("mutation", ["bytes", "version", "build"])
def test_actual_app_changes_are_rejected(tmp_path, mutation):
    fixture = _fixture(tmp_path)
    document = runtime_sbom.build_runtime_sbom(evidence=fixture["evidence"], source_date_epoch=0)
    if mutation == "bytes":
        (fixture["app"] / "Contents/extra").write_bytes(b"different app")
    else:
        path = fixture["app"] / "Contents/Info.plist"
        info = plistlib.loads(path.read_bytes())
        info["CFBundleVersion" if mutation == "build" else "CFBundleShortVersionString"] = "9999"
        path.write_bytes(plistlib.dumps(info))
    with pytest.raises(ValueError, match="candidate app tree differs"):
        _load(fixture)
    with pytest.raises(ValueError, match="candidate app tree differs"):
        runtime_sbom.validate_runtime_sbom(document, evidence=fixture["evidence"])


def test_cli_generation_validation_and_existing_output_preservation(tmp_path, monkeypatch):
    fixture = _fixture(tmp_path)
    output = tmp_path / "runtime.json"
    arguments = [
        "runtime-sbom", "--app", str(fixture["app"]),
        "--proof", str(fixture["proof_path"]), "--expected-proof-sha256", fixture["proof_hash"],
        "--inventory", str(fixture["inventory_path"]),
        "--python-identity", str(fixture["python_path"]),
        "--native-evidence", str(fixture["native_path"]),
    ]
    monkeypatch.setattr(sys, "argv", [*arguments, "--output", str(output), "--source-date-epoch", "0"])
    assert runtime_sbom.main() == 0
    saved = output.read_bytes()
    assert runtime_sbom.main() == 1
    assert output.read_bytes() == saved
    monkeypatch.setattr(sys, "argv", [*arguments, "--validate", str(output)])
    assert runtime_sbom.main() == 0
    assert output.read_bytes() == saved
    invalid_pin = arguments.copy()
    invalid_pin[invalid_pin.index("--expected-proof-sha256") + 1] = "0" * 64
    rejected_output = tmp_path / "rejected.json"
    monkeypatch.setattr(sys, "argv", [*invalid_pin, "--output", str(rejected_output), "--source-date-epoch", "0"])
    assert runtime_sbom.main() == 1
    assert not rejected_output.exists()
