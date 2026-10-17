import hashlib
import importlib.util
import json
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "runtime_notices", ROOT / "packaging/copy_runtime_notices.py"
)
notices = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(notices)


def test_copies_exact_bytes_and_deterministic_manifest(tmp_path):
    runtime = tmp_path / "LICENSE.txt"
    runtime.write_bytes(b"Synthetic Python license\r\n\xff\n")
    core = ROOT / "packaging/licenses/pyobjc-core-12.2.1.txt"
    output = tmp_path / "notices"
    notices.copy_notices(output, runtime, "3.12.13", core, "12.2.1")
    assert (output / "Python.txt").read_bytes() == runtime.read_bytes()
    assert (output / "PyObjC-core.txt").read_bytes() == core.read_bytes()
    manifest_bytes = (output / "runtime-notices.json").read_bytes()
    manifest = json.loads(manifest_bytes)
    assert manifest["components"][0] == {
        "component": "Python", "version": "3.12.13", "file": "Python.txt",
        "sha256": hashlib.sha256(runtime.read_bytes()).hexdigest(),
        "source": "build interpreter stdlib/LICENSE.txt",
    }
    assert manifest["components"][1]["version"] == "12.2.1"
    assert manifest["components"][1]["sha256"] == notices.PYOBJC_SHA256
    assert str(tmp_path).encode() not in manifest_bytes
    notices.copy_notices(output, runtime, "3.12.13", core, "12.2.1")
    assert (output / "runtime-notices.json").read_bytes() == manifest_bytes


@pytest.mark.parametrize("failure", ["missing_python", "core_version", "core_hash", "unknown_python", "empty_python"])
def test_validation_failure_writes_nothing(tmp_path, failure):
    runtime = tmp_path / "LICENSE.txt"
    runtime.write_bytes(b"Synthetic Python license\n")
    core = ROOT / "packaging/licenses/pyobjc-core-12.2.1.txt"
    python_version, core_version = "3.12.13", "12.2.1"
    if failure == "missing_python":
        runtime.unlink()
    elif failure == "empty_python":
        runtime.write_bytes(b" \n")
    elif failure == "core_version":
        core_version = "12.3"
    elif failure == "core_hash":
        core = tmp_path / "core.txt"
        core.write_bytes(b"changed license")
    else:
        python_version = "unknown"
    output = tmp_path / "notices"
    with pytest.raises(ValueError):
        notices.copy_notices(output, runtime, python_version, core, core_version)
    assert not output.exists()


@pytest.fixture
def static_runtime(tmp_path):
    assets = tmp_path / "assets"
    assets.mkdir()
    data = b"Synthetic static library notice\r\n"
    (assets / "library.txt").write_bytes(data)
    sections = {"__text": {"bytes": 12, "sha256": "a" * 64}}
    profile = {
        "schema": 1, "python_version": "3.12.13",
        "target_triple": "aarch64-apple-darwin", "build_release": "20260602",
        "build_options": "pgo+lto", "source_url": "https://example.invalid/runtime.tar.gz",
        "archive_sha256": "b" * 64, "source_manifest_sha256": "c" * 64,
        "text_sections": sections,
        "notices": [{"file": "library.txt", "sha256": hashlib.sha256(data).hexdigest(),
                     "extensions": ["_example"], "libraries": ["example"], "licenses": ["MIT"]}],
    }
    profile_path = tmp_path / "profile.json"
    profile_path.write_text(json.dumps(profile))
    runtime = tmp_path / "LICENSE.txt"
    runtime.write_bytes(b"Synthetic Python notice\n")
    return runtime, profile_path, assets, profile


def copy_static(tmp_path, static_runtime, *, version="3.12.13", sections=None):
    runtime, profile_path, assets, profile = static_runtime
    output = tmp_path / "notices"
    notices.copy_notices(
        output, runtime, version, ROOT / "packaging/licenses/pyobjc-core-12.2.1.txt", "12.2.1",
        runtime_text_sections=profile["text_sections"] if sections is None else sections,
        profile_path=profile_path, notice_directory=assets,
    )
    return output, json.loads((output / "runtime-notices.json").read_bytes())


def test_matching_static_notices_copy_exact_bytes_and_provenance(tmp_path, static_runtime):
    output, manifest = copy_static(tmp_path, static_runtime)
    static = manifest["static_runtime"]
    assert static["state"] == "matched"
    for key in ("source_url", "build_release", "target_triple", "archive_sha256", "source_manifest_sha256"):
        assert static[key] == static_runtime[3][key]
    record = static["notices"][0]
    assert record["extensions"] == ["_example"]
    assert (output / record["file"]).read_bytes() == (static_runtime[2] / "library.txt").read_bytes()
    before = {p.relative_to(output): p.read_bytes() for p in output.rglob("*") if p.is_file()}
    copy_static(tmp_path, static_runtime)
    assert before == {p.relative_to(output): p.read_bytes() for p in output.rglob("*") if p.is_file()}
    assert str(tmp_path) not in json.dumps(manifest)


@pytest.mark.parametrize("version,sections", [("3.12.14", None), ("3.12.13", {}),
    ("3.12.13", {"__text": {"bytes": 13, "sha256": "a" * 64}})])
def test_unknown_static_runtime_retains_base_notices(tmp_path, static_runtime, version, sections):
    output, manifest = copy_static(tmp_path, static_runtime, version=version, sections=sections)
    assert manifest["static_runtime"] == {"state": "unverified", "reason": "runtime_profile_mismatch"}
    assert sorted(p.name for p in output.iterdir()) == ["PyObjC-core.txt", "Python.txt", "runtime-notices.json"]


@pytest.mark.parametrize("failure", ["changed_notice", "unsafe_path", "bad_schema"])
def test_static_source_errors_write_nothing(tmp_path, static_runtime, failure):
    _, path, assets, profile = static_runtime
    if failure == "changed_notice":
        (assets / "library.txt").write_bytes(b"altered")
    elif failure == "unsafe_path":
        profile["notices"][0]["file"] = "../library.txt"
    else:
        profile["schema"] = 2
    path.write_text(json.dumps(profile))
    with pytest.raises(ValueError):
        copy_static(tmp_path, static_runtime)
    assert not (tmp_path / "notices").exists()


def test_unavailable_identity_is_explicit_and_removes_previous_static_notices(tmp_path, static_runtime):
    output, _ = copy_static(tmp_path, static_runtime)
    runtime, profile_path, assets, _ = static_runtime
    notices.copy_notices(
        output, runtime, "3.12.13", ROOT / "packaging/licenses/pyobjc-core-12.2.1.txt", "12.2.1",
        profile_path=profile_path, notice_directory=assets,
    )
    manifest = json.loads((output / "runtime-notices.json").read_bytes())
    assert manifest["static_runtime"] == {"state": "unverified", "reason": "runtime_identity_unavailable"}
    assert sorted(p.name for p in output.iterdir()) == ["PyObjC-core.txt", "Python.txt", "runtime-notices.json"]


@pytest.fixture
def vendor_root(tmp_path):
    import base64
    import csv

    root = tmp_path / "vendor"
    metadata = root / "sample-1.2.dist-info"
    metadata.mkdir(parents=True)
    (metadata / "METADATA").write_text("Metadata-Version: 2.1\nName: sample\nVersion: 1.2\n")
    data = b"Synthetic vendor license\r\n\xff\n"
    (metadata / "LICENSE.txt").write_bytes(data)
    digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()
    with (metadata / "RECORD").open("w", newline="") as stream:
        csv.writer(stream).writerows([
            ["sample-1.2.dist-info/LICENSE.txt", f"sha256={digest}", str(len(data))],
            ["sample-1.2.dist-info/METADATA", "", ""],
            ["sample-1.2.dist-info/RECORD", "", ""],
        ])
    return root


def copy_vendor(tmp_path, static_runtime, vendor_root, parent_version="83.0.0"):
    runtime, profile_path, assets, _ = static_runtime
    output = tmp_path / "notices"
    notices.copy_notices(
        output, runtime, "3.12.13", ROOT / "packaging/licenses/pyobjc-core-12.2.1.txt", "12.2.1",
        profile_path=profile_path, notice_directory=assets,
        vendor_root=vendor_root, parent_version=parent_version,
    )
    return output, json.loads((output / "runtime-notices.json").read_bytes())


def test_vendor_bytes_versions_and_provenance(tmp_path, static_runtime, vendor_root):
    output, manifest = copy_vendor(tmp_path, static_runtime, vendor_root)
    vendor = manifest["setuptools_vendored"]
    assert vendor["parent"] == "setuptools"
    assert vendor["parent_version"] == "83.0.0"
    assert vendor["runtime_membership"] == "unverified"
    assert vendor["scope"] == "Notices supplied with setuptools; runtime membership is unverified."
    distribution = vendor["distributions"][0]
    assert distribution["name"] == "sample"
    assert distribution["version"] == "1.2"
    assert distribution["notice_state"] == "supplied"
    record = distribution["notices"][0]
    data = (vendor_root / "sample-1.2.dist-info/LICENSE.txt").read_bytes()
    assert (output / record["file"]).read_bytes() == data
    assert record["sha256"] == hashlib.sha256(data).hexdigest()
    assert record["source"] == "setuptools/_vendor/sample-1.2.dist-info/LICENSE.txt"
    assert record["bytes"] == len(data)
    assert str(tmp_path) not in json.dumps(manifest)
    assert "used" not in vendor
    before = {p.relative_to(output): p.read_bytes() for p in output.rglob("*") if p.is_file()}
    stale = output / notices.VENDOR_FOLDER / "stale.txt"
    stale.write_bytes(b"stale")
    unrelated = output / "unrelated.txt"
    unrelated.write_bytes(b"keep")
    copy_vendor(tmp_path, static_runtime, vendor_root)
    assert not stale.exists()
    assert unrelated.read_bytes() == b"keep"
    assert all((output / name).read_bytes() == data for name, data in before.items())


@pytest.mark.parametrize("failure", [
    "changed", "missing", "unsafe_path", "symlink", "name", "version", "parent_version", "duplicate",
])
def test_vendor_validation_preserves_existing_output(tmp_path, static_runtime, vendor_root, failure):
    output, _ = copy_vendor(tmp_path, static_runtime, vendor_root)
    before = {p.relative_to(output): p.read_bytes() for p in output.rglob("*") if p.is_file()}
    metadata = vendor_root / "sample-1.2.dist-info"
    license_path = metadata / "LICENSE.txt"
    parent_version = "83.0.0"
    if failure == "changed":
        license_path.write_bytes(b"changed")
    elif failure == "missing":
        license_path.unlink()
    elif failure == "unsafe_path":
        with (metadata / "RECORD").open("a") as stream:
            stream.write("../LICENSE.txt,,\n")
    elif failure == "symlink":
        outside = tmp_path / "outside.txt"
        outside.write_bytes(license_path.read_bytes())
        license_path.unlink()
        license_path.symlink_to(outside)
    elif failure in ("name", "version"):
        text = (metadata / "METADATA").read_text()
        text = text.replace("Name: sample", "Name: ../sample") if failure == "name" else text.replace("Version: 1.2", "Version: ../1.2")
        (metadata / "METADATA").write_text(text)
    elif failure == "parent_version":
        parent_version = "../83"
    else:
        import shutil
        shutil.copytree(metadata, vendor_root / "sample_other-1.2.dist-info")
    with pytest.raises(ValueError):
        copy_vendor(tmp_path, static_runtime, vendor_root, parent_version)
    assert before == {p.relative_to(output): p.read_bytes() for p in output.rglob("*") if p.is_file()}


def test_missing_vendor_notice_is_explicit(tmp_path, static_runtime, vendor_root):
    metadata = vendor_root / "sample-1.2.dist-info"
    (metadata / "LICENSE.txt").unlink()
    (metadata / "RECORD").write_text("sample-1.2.dist-info/METADATA,,\n")
    output, manifest = copy_vendor(tmp_path, static_runtime, vendor_root)
    assert manifest["setuptools_vendored"]["distributions"] == [
        {"name": "sample", "version": "1.2", "notice_state": "missing", "notices": []},
    ]
    assert not (output / notices.VENDOR_FOLDER).exists()


def test_missing_future_vendor_root_removes_stale_notices(tmp_path, static_runtime, vendor_root):
    output, _ = copy_vendor(tmp_path, static_runtime, vendor_root)
    _, manifest = copy_vendor(tmp_path, static_runtime, tmp_path / "absent", "99.0")
    assert manifest["setuptools_vendored"]["state"] == "not_present"
    assert manifest["setuptools_vendored"]["runtime_membership"] == "unverified"
    assert not (output / notices.VENDOR_FOLDER).exists()


def test_vendor_output_symlink_preserves_external_target(tmp_path, static_runtime, vendor_root):
    external = tmp_path / "external"
    external.mkdir()
    sentinel = external / "keep.txt"
    sentinel.write_bytes(b"Synthetic unrelated data\n")
    output = tmp_path / "notices"
    output.mkdir()
    (output / notices.VENDOR_FOLDER).symlink_to(external, target_is_directory=True)
    _, manifest = copy_vendor(tmp_path, static_runtime, vendor_root)
    assert sentinel.read_bytes() == b"Synthetic unrelated data\n"
    assert sorted(path.name for path in external.iterdir()) == ["keep.txt"]
    assert not (output / notices.VENDOR_FOLDER).is_symlink()
    record = manifest["setuptools_vendored"]["distributions"][0]["notices"][0]
    assert (output / record["file"]).is_file()


def test_vendor_unrelated_installer_paths_do_not_block_notices(tmp_path, static_runtime, vendor_root):
    metadata = vendor_root / "sample-1.2.dist-info"
    script = tmp_path / "bin" / "sample"
    script.parent.mkdir()
    script.write_bytes(b"synthetic installer script")
    (vendor_root / "Sample text.txt").write_bytes(b"synthetic package data")
    with (metadata / "RECORD").open("a") as stream:
        stream.write("../bin/sample,,\nSample text.txt,,\n")
    output, manifest = copy_vendor(tmp_path, static_runtime, vendor_root)
    record = manifest["setuptools_vendored"]["distributions"][0]["notices"][0]
    assert (output / record["file"]).read_bytes() == (metadata / "LICENSE.txt").read_bytes()
    assert "bin/sample" not in json.dumps(manifest)


def test_vendor_versions_allow_epochs(tmp_path, static_runtime, vendor_root):
    metadata = vendor_root / "sample-1.2.dist-info" / "METADATA"
    metadata.write_text(metadata.read_text().replace("Version: 1.2", "Version: 1!1.2+local"))
    output, manifest = copy_vendor(tmp_path, static_runtime, vendor_root, "2!83.0.0")
    vendor = manifest["setuptools_vendored"]
    assert vendor["parent_version"] == "2!83.0.0"
    assert vendor["distributions"][0]["version"] == "1!1.2+local"
    assert (output / vendor["distributions"][0]["notices"][0]["file"]).is_file()
