import importlib.metadata
import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "packaging/strip_build_origin.py"


def strip(core):
    spec = importlib.util.spec_from_file_location("strip_build_origin", HELPER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.strip_build_origin(core)


def fixture_core(tmp_path):
    core = tmp_path / "jrbar-core.app"
    resources = core / "Contents/Resources"
    resources.mkdir(parents=True)
    executable = core / "Contents/MacOS/jrbar-core"
    executable.parent.mkdir()
    executable.write_bytes(b"synthetic executable\x00\xff")
    return core, resources, executable


def test_builder_strips_origin_after_freeze_before_assembly():
    source = (ROOT / "packaging/build_macos_pkg.sh").read_text()
    check = source.index('if [ ! -x "$CORE_APP/Contents/MacOS/jrbar-core" ]')
    cleanup = source.index('packaging/strip_build_origin.py" --core-app "$CORE_APP"')
    assert check < cleanup < source.index('echo "==> assembling $APP_PATH"')


@pytest.mark.parametrize("origin", [
    {"url": "file:///synthetic/build/source", "dir_info": {"editable": True}},
    {"url": "https://example.invalid/source", "vcs_info": {"vcs": "git"}},
])
def test_removes_only_origin_and_preserves_distribution_reads(tmp_path, origin):
    core, resources, executable = fixture_core(tmp_path)
    kept = {executable: executable.read_bytes()}
    for relative in ("sample-1.2.dist-info", "vendor/nested-2.0.dist-info"):
        metadata = resources / relative
        metadata.mkdir(parents=True)
        for name, contents in {
            "METADATA": b"Name: sample\nVersion: 1.2\n",
            "RECORD": b"direct_url.json,,\nMETADATA,,\n",
            "LICENSE": b"Synthetic license\r\n\xff",
        }.items():
            path = metadata / name
            path.write_bytes(contents)
            kept[path] = contents
        (metadata / "direct_url.json").write_text(json.dumps(origin))
    other = resources / "direct_url.json"
    other.write_text("keep outside distribution metadata")
    assert strip(core) == 2
    assert strip(core) == 0
    assert other.exists()
    assert not list(resources.rglob("*.dist-info/direct_url.json"))
    assert all(path.read_bytes() == contents for path, contents in kept.items())
    distribution = next(importlib.metadata.distributions(path=[str(resources)]))
    assert distribution.version == "1.2"
    assert distribution.metadata["Name"] == "sample"


def test_no_metadata_is_a_noop(tmp_path):
    core, _, _ = fixture_core(tmp_path)
    assert strip(core) == 0


@pytest.mark.parametrize("link_at", ["core", "contents", "resources", "vendor", "metadata"])
def test_external_directory_symlinks_fail_before_any_deletion(tmp_path, link_at):
    core, resources, _ = fixture_core(tmp_path)
    metadata = resources / "sample-1.dist-info"
    metadata.mkdir()
    origin = metadata / "direct_url.json"
    origin.write_text("synthetic local origin")
    external = tmp_path / "external"
    external.mkdir()
    external_origin = external / "direct_url.json"
    external_origin.write_text("external content")
    if link_at == "core":
        alias = tmp_path / "alias.app"
        alias.symlink_to(core, target_is_directory=True)
        core = alias
    elif link_at in {"contents", "resources"}:
        target = core / "Contents" if link_at == "contents" else resources
        renamed = tmp_path / "saved"
        target.rename(renamed)
        target.symlink_to(renamed, target_is_directory=True)
        origin = renamed / ("Resources/sample-1.dist-info/direct_url.json" if link_at == "contents"
                            else "sample-1.dist-info/direct_url.json")
    else:
        name = "vendor" if link_at == "vendor" else "external-1.dist-info"
        (resources / name).symlink_to(external, target_is_directory=True)
    with pytest.raises(ValueError):
        strip(core)
    assert origin.exists()
    assert external_origin.read_text() == "external content"


def test_origin_file_symlink_unlinks_only_the_link(tmp_path):
    core, resources, _ = fixture_core(tmp_path)
    external = tmp_path / "external.json"
    external.write_text("synthetic external origin")
    metadata = resources / "sample-1.dist-info"
    metadata.mkdir()
    link = metadata / "direct_url.json"
    link.symlink_to(external)
    assert strip(core) == 1
    assert not link.is_symlink()
    assert external.read_text() == "synthetic external origin"


def test_cli_reports_only_count(tmp_path):
    core, resources, _ = fixture_core(tmp_path)
    metadata = resources / "sample-1.dist-info"
    metadata.mkdir()
    secret = "file:///synthetic/private/build/source"
    (metadata / "direct_url.json").write_text(json.dumps({"url": secret}))
    result = subprocess.run([sys.executable, str(HELPER), "--core-app", str(core)],
                            capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr
    assert result.stdout == "Removed 1 installation-origin metadata files.\n"
    assert secret not in result.stdout + result.stderr
