"""Packaging checks consume large listings without breaking their producers."""

import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "scripts/install-agents.sh"
BUILDER = ROOT / "packaging/build_macos_pkg.sh"
REQUIRED = (
    "JR-Bar.app/Contents/MacOS/JR-Bar",
    "JR-Bar.app/Contents/Helpers/jrbar-core.app/Contents/MacOS/jrbar-core",
    "JR-Bar.app/Contents/Helpers/jrbar-hook",
)
# Matches come first, followed by enough output to fill the pipe buffer.
PADDING = "unrelated/fixture/entry\n" * 100_000


def _run(tmp_path: Path, shell: str, body: str, listing: str) -> subprocess.CompletedProcess[str]:
    fixture = tmp_path / "listing"
    fixture.write_text(listing)
    script = tmp_path / "check.sh"
    script.write_text("set -euo pipefail\n" + body)
    return subprocess.run(
        [shell, str(script), str(fixture)],
        capture_output=True, text=True, timeout=10, check=False,
    )


@pytest.mark.parametrize("missing", [None, *REQUIRED])
def test_large_payload_checks_exact_required_paths(tmp_path: Path, missing: str | None) -> None:
    source = INSTALLER.read_text()
    check = source[source.index("            for required in \\\n"):source.index('            validation_dir=')]
    listing = "\n".join(path for path in REQUIRED if path != missing) + "\n"
    if missing:
        listing += f"prefix/{missing}\n{missing}.backup\n"
    result = _run(tmp_path, "/bin/zsh", 'payload="$(cat "$1")"\n' + check, listing + PADDING)

    assert result.returncode == (2 if missing else 0), result.stderr
    if missing:
        assert f"package payload is missing {missing}" in result.stderr


@pytest.mark.parametrize("dirty", [False, True])
def test_dirty_marker_survives_large_git_status(tmp_path: Path, dirty: bool) -> None:
    check = next(line for line in INSTALLER.read_text().splitlines() if line.startswith("DIRTY="))
    result = _run(
        tmp_path, "/bin/zsh",
        'ROOT=fixture\nlisting_file="$1"\ngit() { cat "$listing_file"; }\n'
        + check + '\nprintf "%s\\n" "$DIRTY"\n',
        "?? fixture\n" * 100_000 if dirty else "",
    )

    assert result.returncode == 0, result.stderr
    assert result.stdout == ("-dirty\n" if dirty else "\n")


@pytest.mark.parametrize("identities,expected", [
    ('"Developer ID Application: Fixture (FIXTURE)"\n"Nautilus Local Dev"\n',
     "Developer ID Application: Fixture (FIXTURE)"),
    ('"Nautilus Local Dev"\n', "Nautilus Local Dev"),
    ("", "-"),
])
def test_signing_identity_survives_large_security_listing(
    tmp_path: Path, identities: str, expected: str,
) -> None:
    source = BUILDER.read_text()
    check = source[source.index("select_app_identity() {"):source.index("select_installer_identity() {")]
    security = tmp_path / "security"
    security.write_text('#!/bin/sh\ncat "$IDENTITY_LISTING"\n')
    security.chmod(0o755)
    result = _run(
        tmp_path, "/bin/bash",
        'export IDENTITY_LISTING="$1"\nAPP_SIGN_IDENTITY=\nALLOW_UNSIGNED=0\n'
        + f'SECURITY_TOOL="{security}"\n' + check + "select_app_identity\n",
        identities + PADDING,
    )

    assert result.returncode == 0, result.stderr
    assert result.stdout == expected + "\n"
