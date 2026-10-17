"""Static helper checks use archives of compiled fixtures, never a running daemon."""

from __future__ import annotations

import importlib.util
import json
import marshal
import struct
import subprocess
import sys
import zlib
from pathlib import Path

import pytest
from test_packaging_hardening import run

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "packaging/verify_embedded_core.py"
spec = importlib.util.spec_from_file_location("embedded_core_verifier", SCRIPT)
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


def archive(modules, entry, *, version=None, magic=None, duplicate=False):
    """Emit the pinned PyInstaller CArchive/PYZ layout without its build tools."""
    pyz = bytearray(b"\0" * 17)
    table = []
    for name, (kind, code) in modules.items():
        payload = zlib.compress(marshal.dumps(code))
        table.append((name, (kind, len(pyz), len(payload))))
        pyz.extend(payload)
    if duplicate:
        table.append(table[0])
    toc_offset = len(pyz)
    pyz.extend(marshal.dumps(table))
    pyz[:12] = b"PYZ\0" + (magic or importlib.util.MAGIC_NUMBER) + struct.pack("!i", toc_offset)
    data = bytearray()
    toc = bytearray()
    for name, kind, raw, compress in (
        ("PYZ.pyz", b"z", bytes(pyz), False),
        ("jrbar_entry", b"s", marshal.dumps(entry), True),
    ):
        blob = zlib.compress(raw) if compress else raw
        name_bytes = name.encode() + b"\0"
        length = (verifier.TOC_ENTRY.size + len(name_bytes) + 15) // 16 * 16
        toc.extend(verifier.TOC_ENTRY.pack(length, len(data), len(blob), len(raw), int(compress), kind))
        toc.extend(name_bytes.ljust(length - verifier.TOC_ENTRY.size, b"\0"))
        data.extend(blob)
    toc_offset = len(data)
    data.extend(toc)
    data.extend(verifier.COOKIE.pack(verifier.COOKIE_MAGIC, len(data) + verifier.COOKIE.size,
                                    toc_offset, len(toc), version or sys.version_info.major * 100
                                    + sys.version_info.minor, b"libpython-fixture"))
    # A binary prefix and trailing signature data must not affect archive offsets.
    return b"fixture-bootloader" + data + b"fixture-signature"


def compiled(path):
    return compile(path.read_bytes(), "anonymized-build-path.py", "exec", dont_inherit=True, optimize=0)


@pytest.fixture
def candidate(tmp_path):
    source = tmp_path / "src"
    package = source / "jrbar"
    package.mkdir(parents=True)
    (package / "__init__.py").write_text('"""Fixture package."""\n')
    (package / "capacity_limit_feedback.py").write_text(
        "def notice():\n    return 4\n\nraise RuntimeError('must never execute')\n")
    resources = package / "resources"
    resources.mkdir()
    (resources / "__init__.py").write_text("RESOURCE = 'fixture'\n")
    entry = tmp_path / "packaging/jrbar_entry.py"
    entry.parent.mkdir()
    entry.write_text("raise RuntimeError('entry must never execute')\n")
    modules = {name: (kind, compiled(path)) for name, (kind, path) in verifier.source_modules(source).items()}
    helper = tmp_path / "helper"
    helper.write_bytes(archive(modules, compiled(entry)))
    return source, helper, entry, modules


def test_all_modules_and_separate_entry_are_checked_without_execution(candidate):
    source, helper, _, _ = candidate
    receipt = verifier.verify(helper, source)
    assert receipt["matched"]
    assert receipt["expected_modules"] == len(receipt["modules"]) == 3
    assert receipt["entry_point"]["matched"]
    assert receipt["modules"]["jrbar.resources"]["matched"]


@pytest.mark.parametrize("change", ["missing", "extra", "nested-stale", "package-kind", "entry-stale"])
def test_partial_or_stale_helper_fails(candidate, change):
    source, helper, entry, modules = candidate
    if change == "missing":
        del modules["jrbar.capacity_limit_feedback"]
    elif change == "extra":
        modules["jrbar.retired"] = (0, compile("x = 1", "fixture.py", "exec"))
    elif change == "nested-stale":
        modules["jrbar.capacity_limit_feedback"] = (0, compile("def notice():\n    return 99\n", "x", "exec"))
    elif change == "package-kind":
        modules["jrbar.resources"] = (0, modules["jrbar.resources"][1])
    entry_code = compile("pass", "x", "exec") if change == "entry-stale" else compiled(entry)
    helper.write_bytes(archive(modules, entry_code))
    receipt = verifier.verify(helper, source)
    assert not receipt["matched"]
    if change == "missing":
        assert receipt["missing_modules"] == ["jrbar.capacity_limit_feedback"]
    if change == "extra":
        assert receipt["unexpected_modules"] == ["jrbar.retired"]


@pytest.mark.parametrize("change", ["version", "magic", "duplicate", "truncated", "empty-source"])
def test_malformed_or_incompatible_input_fails_closed(candidate, change):
    source, helper, entry, modules = candidate
    kwargs = {"version": 999} if change == "version" else {}
    if change == "magic":
        kwargs["magic"] = b"bad!"
    if change == "duplicate":
        kwargs["duplicate"] = True
    payload = archive(modules, compiled(entry), **kwargs)
    helper.write_bytes(payload[:20] if change == "truncated" else payload)
    if change == "empty-source":
        source = source / "absent"
    receipt = verifier.verify(helper, source)
    assert not receipt["matched"]
    assert "error_type" in receipt


def test_cli_writes_failure_receipt_and_returns_failure(candidate, tmp_path):
    source, helper, _, _ = candidate
    (source / "jrbar/capacity_limit_feedback.py").write_text("SECRET_FIXTURE = 'never-print-me'\n")
    output = tmp_path / "receipt.json"
    result = subprocess.run([sys.executable, str(SCRIPT), str(helper), str(source), str(output)],
                            capture_output=True, text=True, timeout=10)
    assert result.returncode == 1
    assert not json.loads(output.read_text())["matched"]
    assert "never-print-me" not in result.stdout + result.stderr + output.read_text()


def test_discovery_covers_current_package_and_new_quota_helpers():
    modules = verifier.source_modules(ROOT / "src")
    assert len(modules) == len(list((ROOT / "src/jrbar").rglob("*.py")))
    assert {"jrbar", "jrbar.resources", "jrbar.capacity_limit_feedback", "jrbar.collector",
            "jrbar.provider_facts", "jrbar.operator_state", "jrbar.controller_attributes"} <= modules.keys()


def test_complete_current_source_roundtrip(tmp_path):
    source = ROOT / "src"
    modules = {name: (kind, compiled(path)) for name, (kind, path) in verifier.source_modules(source).items()}
    helper = tmp_path / "synthetic-helper"
    helper.write_bytes(archive(modules, compiled(ROOT / "packaging/jrbar_entry.py")))
    receipt = verifier.verify(helper, source)
    assert receipt["matched"]
    assert receipt["expected_modules"] == len(modules)
    assert receipt["entry_point"]["matched"]


@pytest.mark.parametrize("stale", [False, True])
def test_real_static_verifier_controls_packaging_submission(candidate, tmp_path, stale):
    source, helper, _, _ = candidate
    helpers = tmp_path / "bundled-helpers"
    bundled = helpers / "jrbar-core.app/Contents/MacOS/jrbar-core"
    bundled.parent.mkdir(parents=True)
    bundled.write_bytes(helper.read_bytes())
    if stale:
        (source / "jrbar/capacity_limit_feedback.py").write_text("NOTICE_SECONDS = 99\n")
    result = run(tmp_path, "require_production_candidate\nverify_embedded_source\necho SUBMITTED\n",
                 EMBEDDED_SOURCE_VERIFY_SCRIPT=str(SCRIPT), ROOT_DIR=str(source.parent), HELPERS=str(helpers))
    receipt = json.loads((tmp_path / "evidence/embedded-source-verification.json").read_text())
    assert receipt["matched"] is not stale
    assert (result.returncode == 0) is not stale
    assert ("SUBMITTED" in result.stdout) is not stale
