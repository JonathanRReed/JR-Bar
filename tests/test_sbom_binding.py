import copy
import json
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

from scripts import generate_sbom, release_evidence


@pytest.fixture
def candidate(tmp_path, monkeypatch):
    app = tmp_path / "Candidate.app"
    app.mkdir()
    (app / "binary").write_bytes(b"synthetic executable")
    artifact = tmp_path / "candidate.pkg"
    artifact.write_bytes(b"synthetic package")
    monkeypatch.setenv("SOURCE_DATE_EPOCH", "0")
    monkeypatch.setattr(generate_sbom.importlib.metadata, "distributions", lambda: ())
    return app, artifact, tmp_path


def build(candidate):
    app, artifact, root = candidate
    return generate_sbom.build_sbom(application_version="1.2.3", app=app,
                                    artifacts=(artifact,), root=root)


def validate(document, candidate):
    app, artifact, root = candidate
    generate_sbom.validate_sbom(document, application_version="1.2.3", app=app,
                               artifacts=(artifact,), root=root)


def test_binding_and_build_scope(candidate, monkeypatch):
    monkeypatch.setattr(generate_sbom.importlib.metadata, "distributions", lambda: [
        SimpleNamespace(metadata={"Name": "Example"}, version="1")])
    document = build(candidate)
    validate(document, candidate)
    props = document["metadata"]["component"]["properties"]
    assert {p["name"]: p["value"] for p in props}["jrbar:app:sha256"] == release_evidence.sha256_tree(candidate[0])
    assert document["components"][0]["properties"] == [{"name": "jrbar:scope", "value": "build-environment"}]
    assert document["metadata"]["lifecycles"] == [{"phase": "build"}]
    assert document["compositions"][0]["aggregate"] == "incomplete"


@pytest.mark.parametrize("mutation", ["bytes", "mode", "wrong-copy"])
def test_changed_app_rejected(candidate, mutation):
    document = build(candidate)
    binary = candidate[0] / "binary"
    if mutation == "mode":
        binary.chmod(0o755)
    elif mutation == "bytes":
        binary.write_bytes(b"changed")
    else:
        other = candidate[2] / "Other.app"
        other.mkdir()
        (other / "binary").write_bytes(b"other copy")
        candidate = other, candidate[1], candidate[2]
    with pytest.raises(ValueError):
        validate(document, candidate)


@pytest.mark.parametrize("mutation", ["binding", "digest", "size", "duplicate", "format", "spec", "version", "name", "phase", "coverage", "graph", "components", "component", "duplicate-ref", "scope"])
def test_invalid_evidence_rejected(candidate, mutation):
    document = build(candidate)
    component = document["metadata"]["component"]
    props = component["properties"]
    if mutation == "binding":
        component["properties"] = [p for p in props if p["name"] != "jrbar:app:sha256"]
    elif mutation in {"digest", "size"}:
        suffix = "sha256" if mutation == "digest" else "bytes"
        next(p for p in props if p["name"].startswith("jrbar:artifact:") and p["name"].endswith(suffix))["value"] = "0"
    elif mutation == "duplicate":
        props.append(copy.deepcopy(props[0]))
    elif mutation == "format":
        document["bomFormat"] = "other"
    elif mutation == "spec":
        document["specVersion"] = "1.4"
    elif mutation in {"version", "name"}:
        component[mutation] = "other"
    elif mutation == "phase":
        document["metadata"]["lifecycles"] = [{"phase": "operations"}]
    elif mutation == "coverage":
        document["compositions"][0]["aggregate"] = "complete"
    elif mutation == "graph":
        document["dependencies"] = [{"ref": component["bom-ref"], "dependsOn": []}]
    elif mutation == "components":
        document["components"] = {}
    else:
        env = {"type": "library", "name": "example", "version": "1", "bom-ref": "pkg:pypi/example@1", "purl": "pkg:pypi/example@1", "properties": [{"name": "jrbar:scope", "value": "build-environment"}]}
        document["components"] = [env]
        if mutation == "component":
            del env["name"]
        elif mutation == "duplicate-ref":
            document["components"].append(copy.deepcopy(env))
        else:
            env["properties"][0]["value"] = "runtime"
    with pytest.raises(ValueError):
        validate(document, candidate)


def test_deterministic_order(candidate, monkeypatch):
    distributions = [SimpleNamespace(metadata={"Name": n}, version="1") for n in ("b", "a")]
    monkeypatch.setattr(generate_sbom.importlib.metadata, "distributions", lambda: distributions)
    first = build(candidate)
    distributions.reverse()
    assert build(candidate) == first


def test_cli_validation_failure_preserves_output(candidate):
    app, artifact, root = candidate
    evidence = root / "sbom.json"
    evidence.write_text(json.dumps({"bomFormat": "fake"}))
    output = root / "output.json"
    command = [sys.executable, str(Path(generate_sbom.__file__)), "--validate", str(evidence),
               "--app", str(app), "--application-version", "1.2.3", "--artifact", str(artifact),
               "--root", str(root), "--output", str(output)]
    result = subprocess.run(command, capture_output=True, text=True, timeout=30)
    assert result.returncode == 1
    assert not output.exists()
    assert json.loads(evidence.read_text()) == {"bomFormat": "fake"}


@pytest.mark.parametrize("field", ["sha256", "bytes"])
def test_missing_artifact_property_rejected(candidate, field):
    document = build(candidate)
    props = document["metadata"]["component"]["properties"]
    document["metadata"]["component"]["properties"] = [
        item for item in props if item["name"] != f"jrbar:artifact:candidate.pkg:{field}"
    ]
    with pytest.raises(ValueError):
        validate(document, candidate)


def test_cli_generation_and_validation(candidate):
    app, artifact, root = candidate
    evidence = root / "sbom.json"
    command = [sys.executable, str(Path(generate_sbom.__file__)), "--app", str(app),
               "--application-version", "1.2.3", "--artifact", str(artifact), "--root", str(root)]
    generated = subprocess.run([*command, "--output", str(evidence)], capture_output=True,
                               text=True, timeout=30)
    assert generated.returncode == 0, generated.stderr
    document = json.loads(evidence.read_text())
    validate(document, candidate)
    checked = subprocess.run([*command, "--validate", str(evidence)], capture_output=True,
                             text=True, timeout=30)
    assert checked.returncode == 0, checked.stderr
    assert json.loads(evidence.read_text()) == document


def test_cli_failed_generation_preserves_existing_evidence(candidate):
    app, artifact, root = candidate
    evidence = root / "sbom.json"
    evidence.write_text("existing evidence\n")
    artifact.unlink()
    result = subprocess.run([
        sys.executable, str(Path(generate_sbom.__file__)), "--app", str(app),
        "--application-version", "1.2.3", "--artifact", str(artifact),
        "--root", str(root), "--output", str(evidence),
    ], capture_output=True, text=True, timeout=30)
    assert result.returncode == 1
    assert evidence.read_text() == "existing evidence\n"
