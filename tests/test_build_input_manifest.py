"""Build-input receipts use temporary repositories and no build tools."""
import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

MODULE_PATH = Path(__file__).parents[1] / "packaging" / "build_input_manifest.py"
spec = importlib.util.spec_from_file_location("build_input_manifest", MODULE_PATH)
assert spec is not None and spec.loader is not None
manifest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manifest)


@pytest.fixture
def repository(tmp_path):
    root = tmp_path / "repo"
    root.mkdir()
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    (root / ".gitignore").write_text("build/\ndist/\n")
    for name in ("app/Main.swift", "src/core.py", "hook/main.c", "packaging/build.sh", "requirements/release-lock.txt", "pyproject.toml"):
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("fixture\n")
    subprocess.run(["git", "-C", str(root), "add", "."], check=True)
    return root, tmp_path / "inputs.json"


def test_dirty_and_untracked_inputs_are_bound(repository):
    root, receipt = repository
    (root / "app/Main.swift").write_text("dirty before capture\n")
    (root / "src/new.py").write_text("untracked\n")
    manifest.capture(root, receipt, [])
    manifest.verify(root, receipt)
    document = json.loads(receipt.read_text())
    assert "src/new.py" in document["inputs"]
    assert list(document["inputs"]) == sorted(document["inputs"])


@pytest.mark.parametrize("name", ["app/Main.swift", "hook/main.c", "requirements/release-lock.txt"])
def test_changed_build_input_fails(repository, name):
    root, receipt = repository
    manifest.capture(root, receipt, [])
    (root / name).write_text("changed\n")
    with pytest.raises(ValueError, match="Build inputs changed"):
        manifest.verify(root, receipt)


def test_added_and_deleted_untracked_inputs_fail(repository):
    root, receipt = repository
    path = root / "src/extra.py"
    manifest.capture(root, receipt, [])
    path.write_text("added\n")
    with pytest.raises(ValueError, match=r"src/extra\.py"):
        manifest.verify(root, receipt)
    manifest.capture(root, receipt, [])
    path.unlink()
    with pytest.raises(ValueError, match=r"src/extra\.py"):
        manifest.verify(root, receipt)


def test_missing_tracked_file_fails(repository):
    root, receipt = repository
    manifest.capture(root, receipt, [])
    (root / "hook/main.c").unlink()
    with pytest.raises(FileNotFoundError):
        manifest.verify(root, receipt)
    with pytest.raises(FileNotFoundError):
        manifest.capture(root, receipt, [])


def test_executable_mode_is_bound(repository):
    root, receipt = repository
    path = root / "packaging/build.sh"
    manifest.capture(root, receipt, [])
    path.chmod(path.stat().st_mode | 0o100)
    with pytest.raises(ValueError, match=r"packaging/build\.sh"):
        manifest.verify(root, receipt)


def test_excluded_outputs_and_receipt_do_not_change_inputs(repository):
    root, _ = repository
    receipt = root / "build" / "evidence" / "inputs.json"
    manifest.capture(root, receipt, [str(root / "build"), str(root / "dist")])
    (root / "dist").mkdir()
    (root / "dist" / "candidate.pkg").write_bytes(b"artifact")
    (root / "build" / "generated").write_bytes(b"generated")
    manifest.verify(root, receipt)


@pytest.mark.parametrize("excluded", ["", ".", "..", ".git", "app", "app/Sources", "src", "hook", "packaging", "scripts", "requirements", "pyproject.toml"])
def test_unsafe_exclusions_are_rejected(repository, excluded):
    root, receipt = repository
    with pytest.raises(ValueError, match="Exclusion"):
        manifest.capture(root, receipt, [excluded])


def test_tracked_file_in_output_directory_cannot_be_excluded(repository):
    root, receipt = repository
    path = root / "build" / "input.txt"
    path.parent.mkdir()
    path.write_text("real input\n")
    subprocess.run(["git", "-C", str(root), "add", "-f", "build/input.txt"], check=True)
    with pytest.raises(ValueError, match="tracked inputs"):
        manifest.capture(root, receipt, [str(root / "build")])


def test_symlink_target_and_content_are_bound(repository):
    root, receipt = repository
    link = root / "src" / "linked.py"
    link.symlink_to("core.py")
    manifest.capture(root, receipt, [])
    (root / "src/core.py").write_text("new content\n")
    with pytest.raises(ValueError, match=r"linked\.py"):
        manifest.verify(root, receipt)
    manifest.capture(root, receipt, [])
    link.unlink()
    link.symlink_to("../hook/main.c")
    with pytest.raises(ValueError, match=r"linked\.py"):
        manifest.verify(root, receipt)


def test_external_symlink_and_unsupported_entry_fail(repository):
    root, receipt = repository
    outside = root.parent / "outside.txt"
    outside.write_text("outside\n")
    link = root / "src/external.py"
    link.symlink_to(outside)
    with pytest.raises(ValueError, match="ROOT"):
        manifest.capture(root, receipt, [])
    link.unlink()
    fifo = root / "src/core.py"
    fifo.unlink()
    os.mkfifo(fifo)
    with pytest.raises(ValueError, match="Unsupported source entry"):
        manifest.capture(root, receipt, [])


def test_validate_cli_rejects_source_exclusion_before_any_output_exists(repository):
    root, receipt = repository
    result = subprocess.run([sys.executable, str(MODULE_PATH), "validate", str(root), "--exclude", str(root / "src")],
                            capture_output=True, text=True)
    assert result.returncode == 1
    assert "Exclusion overlaps source inputs" in result.stderr
    assert not receipt.exists()


def test_explicit_deleted_input_allowance_is_bound(repository):
    root, receipt = repository
    deleted = root / "hook/main.c"
    deleted.unlink()
    manifest.capture(root, receipt, [], allow_deleted=True)
    document = json.loads(receipt.read_text())
    assert document["deleted_inputs"] == ["hook/main.c"]
    assert "hook/main.c" not in document["inputs"]
    manifest.verify(root, receipt)
    deleted.write_text("restored\n")
    with pytest.raises(ValueError, match="Deleted inputs changed"):
        manifest.verify(root, receipt)
    deleted.unlink()
    (root / "src/core.py").unlink()
    with pytest.raises(ValueError, match="Deleted inputs changed"):
        manifest.verify(root, receipt)


def test_deleted_input_must_remain_tracked(repository):
    root, receipt = repository
    (root / "hook/main.c").unlink()
    manifest.capture(root, receipt, [], allow_deleted=True)
    subprocess.run(["git", "-C", str(root), "rm", "--cached", "hook/main.c"], check=True)
    with pytest.raises(ValueError, match="Deleted inputs changed"):
        manifest.verify(root, receipt)


@pytest.mark.parametrize("deleted", [None, "hook/main.c", [1], ["../outside"], ["/outside"],
                                     ["hook/main.c", "hook/main.c"], ["src/../hook/main.c"]])
def test_malformed_deleted_inputs_are_rejected(repository, deleted):
    root, receipt = repository
    manifest.capture(root, receipt, [])
    document = json.loads(receipt.read_text())
    document["deleted_inputs"] = deleted
    receipt.write_text(json.dumps(document))
    with pytest.raises(ValueError, match="deleted_inputs"):
        manifest.verify(root, receipt)


@pytest.mark.parametrize("external", [False, True])
def test_deleted_allowance_rejects_broken_and_external_symlinks(repository, external):
    root, receipt = repository
    (root / "hook/main.c").unlink()
    target = root.parent / "outside" if external else root / "missing"
    if external:
        target.write_text("outside\n")
    (root / "src/core.py").unlink()
    (root / "src/core.py").symlink_to(target)
    with pytest.raises((ValueError, FileNotFoundError)):
        manifest.capture(root, receipt, [], allow_deleted=True)


@pytest.mark.parametrize("verifying", [False, True])
def test_deleted_allowance_rejects_external_parent_symlink(repository, verifying):
    root, receipt = repository
    (root / "hook/main.c").unlink()
    if verifying:
        manifest.capture(root, receipt, [], allow_deleted=True)
    (root / "hook").rmdir()
    outside = root.parent / "outside"
    outside.mkdir()
    (root / "hook").symlink_to(outside, target_is_directory=True)
    with pytest.raises(ValueError, match="ROOT"):
        if verifying:
            manifest.verify(root, receipt)
        else:
            manifest.capture(root, receipt, [], allow_deleted=True)


def test_deleted_allowance_rejects_unsupported_entries(repository):
    root, receipt = repository
    (root / "hook/main.c").unlink()
    (root / "src/core.py").unlink()
    os.mkfifo(root / "src/core.py")
    with pytest.raises(ValueError, match="Unsupported source entry"):
        manifest.capture(root, receipt, [], allow_deleted=True)


def test_capture_cli_requires_explicit_deleted_allowance(repository):
    root, receipt = repository
    (root / "hook/main.c").unlink()
    strict = subprocess.run([sys.executable, str(MODULE_PATH), "capture", str(root), str(receipt)],
                            capture_output=True, text=True)
    assert strict.returncode == 1
    allowed = subprocess.run([sys.executable, str(MODULE_PATH), "capture", str(root), str(receipt), "--allow-deleted"],
                             capture_output=True, text=True)
    assert allowed.returncode == 0, allowed.stderr
    manifest.verify(root, receipt)


@pytest.mark.parametrize("allow_deleted", [None, "1"])
def test_builder_deleted_allowance_is_capture_only(tmp_path, allow_deleted):
    source = MODULE_PATH.with_name("build_macos_pkg.sh").read_text()
    capture = "capture_build_inputs() {" + source.split("capture_build_inputs() {", 1)[1].split("\n}", 1)[0] + "\n}"
    verify = source.split("verify_build_inputs() {", 1)[1].split("\n}", 1)[0]
    assert "--allow-deleted" not in verify
    recorder = tmp_path / "record.py"
    output = tmp_path / "arguments.json"
    recorder.write_text("import json, os, sys\nfrom pathlib import Path\n"
                        "Path(os.environ['ARGUMENT_OUTPUT']).write_text(json.dumps(sys.argv[1:]))\n")
    environment = os.environ.copy()
    environment.pop("JRBAR_ALLOW_DELETED_BUILD_INPUTS", None)
    environment.update(BUILD_PYTHON=sys.executable, ROOT_DIR=str(tmp_path),
                       RAW_EVIDENCE_DIR=str(tmp_path / "evidence"), BUILD_DIR=str(tmp_path / "build"),
                       DIST_DIR=str(tmp_path / "dist"), ARGUMENT_OUTPUT=str(output))
    if allow_deleted is not None:
        environment["JRBAR_ALLOW_DELETED_BUILD_INPUTS"] = allow_deleted
    capture = capture.replace('"$ROOT_DIR/packaging/build_input_manifest.py"', '"$CAPTURE_TOOL"')
    environment["CAPTURE_TOOL"] = str(recorder)
    result = subprocess.run(["/bin/bash", "-eu", "-c", capture + "\ncapture_build_inputs"],
                            env=environment, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    arguments = json.loads(output.read_text())
    expected = ["capture", str(tmp_path), str(tmp_path / "evidence/build-inputs.json"),
                "--exclude", str(tmp_path / "build"), "--exclude", str(tmp_path / "dist")]
    if allow_deleted == "1":
        expected.append("--allow-deleted")
    assert arguments == expected
