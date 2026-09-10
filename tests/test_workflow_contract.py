"""What GitHub Actions is allowed to do for JR-Bar.

The whole point of these tests is the boundary: hosted runners check the
source, and the owner's Mac makes the release. Nothing in `.github/workflows`
may sign, notarize, publish an update feed, or run repository code on a
machine that holds the Developer ID key.

`.github/workflows/self-hosted-macos.yml` was retired on 2026-09-10. It
targeted a `sidepulse-production` self-hosted runner that never existed, and
the only Mac that could have hosted one is the owner's, whose login keychain
holds the Developer ID Application identity, the notary profile and the
Sparkle private key. `scripts/verify_macos_release.sh` is an at-the-keyboard
gate (TCC prompts, an installed app, optionally a physical device), so there
was nothing left for the job to do that `tests.yml` does not already do.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
_ACTION_USE = re.compile(r"uses:\s+[^@\s]+@([^\s#]+)")
_COMMIT_SHA = re.compile(r"[0-9a-f]{40}\Z")
# Names the release gate and the packaging script read out of the keychain.
_RELEASE_SECRET_NAMES = (
    "APP_SIGN_IDENTITY",
    "INSTALLER_SIGN_IDENTITY",
    "NOTARY_PROFILE",
    "SPARKLE_KEY_ACCOUNT",
    "SPARKLE_PRIVATE_KEY",
    "NOTARY_PASSWORD",
)


def _workflows() -> tuple[Path, ...]:
    return tuple(sorted(WORKFLOWS.glob("*.yml")))


def test_tests_run_for_pull_requests_and_pushes_on_hosted_macos() -> None:
    text = (WORKFLOWS / "tests.yml").read_text(encoding="utf-8")

    assert "workflow_dispatch:" in text
    assert "\n  push:" in text
    assert "\n  pull_request:" in text
    assert "security:" in text
    security = text.split("  security:", 1)[1].split("\n  macos:", 1)[0]
    assert "runs-on: macos-latest" in security
    assert "self-hosted" not in security


def test_hosted_tests_cover_the_three_gates_a_contributor_runs_locally() -> None:
    text = (WORKFLOWS / "tests.yml").read_text(encoding="utf-8")

    assert "make fast" in text
    assert "-m pytest tests -q" in text
    # 0.8 ships a Swift app over the Python daemon; the Swift package is a
    # first-class gate, not an optional extra.
    assert "swift:" in text
    assert "swift build" in text
    assert "swift test" in text


def test_publish_workflow_remains_manual_only() -> None:
    text = (WORKFLOWS / "publish.yml").read_text(encoding="utf-8")

    assert "workflow_dispatch:" in text
    assert "\n  push:" not in text
    assert "\n  pull_request:" not in text


def test_fork_workflow_does_not_publish_upstream_pypi_name() -> None:
    text = (WORKFLOWS / "publish.yml").read_text(encoding="utf-8")

    assert "gh-action-pypi-publish" not in text
    assert "upload-artifact" in text
    assert "scripts/validate_release_version.py" in text


def test_every_third_party_action_is_pinned_to_an_immutable_commit() -> None:
    for workflow in _workflows():
        text = workflow.read_text(encoding="utf-8")
        refs = _ACTION_USE.findall(text)
        assert refs, f"{workflow.name} declares no action steps"
        assert all(_COMMIT_SHA.fullmatch(ref) for ref in refs), (
            f"{workflow.name} contains a floating action reference: {refs}"
        )


def test_the_retired_self_hosted_production_workflow_stays_retired() -> None:
    assert not (WORKFLOWS / "self-hosted-macos.yml").exists()
    assert _workflows(), "the workflow directory is empty"


def test_no_workflow_runs_repository_code_on_a_self_hosted_runner() -> None:
    for workflow in _workflows():
        text = workflow.read_text(encoding="utf-8")
        assert "self-hosted" not in text, f"{workflow.name} targets a self-hosted runner"
        for line in text.splitlines():
            stripped = line.strip()
            if stripped.startswith("runs-on:"):
                assert "macos-" in stripped or "ubuntu-" in stripped, (
                    f"{workflow.name} runs on an unreviewed runner: {stripped}"
                )


def test_no_workflow_can_reach_the_signing_notary_or_sparkle_material() -> None:
    for workflow in _workflows():
        text = workflow.read_text(encoding="utf-8")
        for name in _RELEASE_SECRET_NAMES:
            assert name not in text, f"{workflow.name} names release material {name}"
        assert "codesign" not in text
        assert "notarytool" not in text
        assert "verify_macos_release.sh" not in text
        assert "publish_release.sh" not in text
        assert "build_macos_pkg.sh" not in text


def test_no_workflow_writes_to_the_repository_or_a_release() -> None:
    for workflow in _workflows():
        text = workflow.read_text(encoding="utf-8")
        assert "permissions:" in text, f"{workflow.name} declares no permissions block"
        assert "contents: write" not in text
        assert "id-token:" not in text
        assert "packages: write" not in text
        assert "gh release" not in text


def test_release_documentation_names_the_owner_mac_as_the_only_release_path() -> None:
    release_doc = (ROOT / "docs" / "PRODUCTION-RELEASE.md").read_text(encoding="utf-8")

    assert "make package" in release_doc
    assert "scripts/verify_macos_release.sh" in release_doc
    assert "scripts/publish_release.sh" in release_doc
    # The retirement has to be written down where a releaser will read it.
    assert "self-hosted" in release_doc
