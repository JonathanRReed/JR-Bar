from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILD_SCRIPT = ROOT / "packaging" / "build_macos_pkg.sh"
HOOK_BENCHMARK = ROOT / "scripts" / "benchmark_hook_ingress.py"
INSTALL_SCRIPT = ROOT / "scripts" / "install-agents.sh"
LSREGISTER = (
    "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/"
    "LaunchServices.framework/Versions/A/Support/lsregister"
)


def test_package_builder_fails_fast_and_never_defaults_to_apple_python_39__and_2_more() -> None:
    # --- scenario: package_builder_fails_fast_and_never_defaults_to_apple_python_39
    text = BUILD_SCRIPT.read_text(encoding="utf-8")

    assert "set -euo pipefail" in text
    assert 'BUILD_PYTHON="${BUILD_PYTHON:-/usr/bin/python3}"' not in text
    assert "JR-Bar release packaging requires Python 3.12" in text
    assert "sys.version_info[:2] != (3, 12)" in text
    assert "scripts/validate_release_version.py" in text

    # --- scenario: release_build_selects_the_locked_python_runtime
    text = BUILD_SCRIPT.read_text(encoding="utf-8")

    assert "/opt/homebrew/bin/python3.12" in text
    assert "python3.12" in text
    assert "sys.version_info[:2] != (3, 12)" in text
    assert "JR-Bar release packaging requires Python 3.12." in text

    # --- scenario: source_install_drops_only_the_incompatible_build_constraint
    text = BUILD_SCRIPT.read_text(encoding="utf-8")

    assert (
        'env -u PIP_BUILD_CONSTRAINT "$VENV_DIR/bin/python" -m pip install '
        '"$ROOT_DIR" --no-deps --no-build-isolation'
    ) in text
    assert 'export PIP_CONSTRAINT="$CONSTRAINTS"' in text
    assert 'export PIP_BUILD_CONSTRAINT="$CONSTRAINTS"' in text



def test_package_builder_embeds_creator_micro_backend__and_2_more() -> None:
    # --- scenario: package_builder_embeds_creator_micro_backend
    text = BUILD_SCRIPT.read_text(encoding="utf-8")

    assert "--hidden-import jrbar.creator_micro_adapter" in text
    assert "--hidden-import jrbar.creator_micro_hidapi" in text
    assert "--hidden-import hid" in text

    # --- scenario: package_builder_embeds_distribution_metadata_for_runtime_version
    text = BUILD_SCRIPT.read_text(encoding="utf-8")

    assert "--copy-metadata jrbar" in text

    # --- scenario: package_builder_sets_display_name_without_changing_bundle_identity
    text = BUILD_SCRIPT.read_text(encoding="utf-8")

    assert 'PRODUCT_DISPLAY_NAME="JR-Bar"' in text
    assert ":CFBundleDisplayName string $PRODUCT_DISPLAY_NAME" in text
    assert ":CFBundleName string $PRODUCT_DISPLAY_NAME" in text
    assert 'MINIMUM_SUPPORTED_MACOS="26.0"' in text
    assert ":LSMinimumSystemVersion string $MINIMUM_SUPPORTED_MACOS" in text
    assert "--name jrbar-core" in text
    assert 'APP_ID="com.jonathanreed.jrbar"' in text
    assert 'CORE_ID="com.jonathanreed.jrbar.core"' in text



def test_package_builder_assembles_the_swift_app_daemon_and_shim__and_2_more() -> None:
    # --- scenario: package_builder_assembles_the_swift_app_daemon_and_shim
    text = BUILD_SCRIPT.read_text(encoding="utf-8")

    # The Swift app is the bundle; the frozen daemon and the shim ride under Helpers.
    assert 'APP_BUILD_SCRIPT="${APP_BUILD_SCRIPT:-$ROOT_DIR/app/scripts/build-app.sh}"' in text
    assert 'HOOK_BUILD_SCRIPT="${HOOK_BUILD_SCRIPT:-$ROOT_DIR/hook/build.sh}"' in text
    assert 'JRBAR_BUNDLE="$SWIFT_APP" JRBAR_VERSION="$VERSION" JRBAR_SKIP_SIGN=1 \\\n    JRBAR_SPARKLE_FRAMEWORK_DIR="$SPARKLE_DISTRIBUTION" JRBAR_EMBED_SPARKLE=0 "$APP_BUILD_SCRIPT"' in text
    # Sparkle is prepared before the app build so the app can link it.
    assert text.index('prepare_sparkle.py') < text.index('"$APP_BUILD_SCRIPT"\n')
    assert 'JRBAR_HOOK_BUILD_DIR="$HOOK_DIR" "$HOOK_BUILD_SCRIPT"' in text
    assert "--onedir --windowed" in text
    assert '--osx-bundle-identifier "$CORE_ID"' in text
    assert "--collect-submodules jrbar" in text
    assert '/usr/bin/ditto "$CORE_APP" "$HELPERS/jrbar-core.app"' in text
    assert '/usr/bin/install -m 755 "$HOOK_DIR/jrbar-hook" "$HELPERS/jrbar-hook"' in text
    assert "packaging/jrbar_entry.py" in text
    # The daemon bundle is headless and the app hands the daemon its commit.
    assert 'Add :LSUIElement bool true" "$CORE_PLIST"' in text
    # App Nap must never defer the daemon: its whole job is timeliness.
    assert 'Add :LSAppNapIsDisabled bool true" "$CORE_PLIST"' in text
    assert ":JRBarCommit string $COMMIT" in text
    # Everything the old PyInstaller UI bundle needed is gone.
    assert "--collect-submodules Cocoa" in text
    assert "status-bar" not in text

    # --- scenario: package_builder_picks_the_best_keychain_identity_and_notarizes_when_it_can
    text = BUILD_SCRIPT.read_text(encoding="utf-8")

    selector = text[text.index("select_app_identity() {"):text.index("select_installer_identity() {")]
    developer = selector.index('"Developer ID Application: ')
    local = selector.index('"Nautilus Local Dev"')
    adhoc = selector.index("printf -- '-\\n'", local)
    assert developer < local < adhoc
    assert 'NOTARY_PROFILE="${NOTARY_PROFILE:-jrbar-notary}"' in text
    assert 'notarytool history --keychain-profile "$NOTARY_PROFILE"' in text
    assert "not notarized" in text
    assert 'Developer ID Installer: ' in text
    # A local identity has no Team ID: it cannot pass library validation, so
    # the hardened runtime and the timestamp are Developer ID only.
    assert "sign_args+=(--no-runtime)" in text
    assert "sign_args+=(--no-timestamp)" in text
    # The keychain is never consulted in the local-only mode the tests run.
    assert 'if [ "$ALLOW_UNSIGNED" = "1" ]; then' in text

    # --- scenario: package_builder_verifies_delivered_signature_identity
    text = BUILD_SCRIPT.read_text(encoding="utf-8")
    signer = (ROOT / "packaging" / "sign_macos_app.py").read_text(encoding="utf-8")

    assert "TeamIdentifier" in text
    assert "verify_macos_app.py" in text
    # The strict deep verification now lives in the signer the script runs.
    assert "packaging/sign_macos_app.py" in text
    for flag in ('"--verify"', '"--deep"', '"--strict"'):
        assert flag in signer



def test_package_builder_retains_structured_notarization_evidence__and_2_more() -> None:
    # --- scenario: package_builder_retains_structured_notarization_evidence
    text = BUILD_SCRIPT.read_text(encoding="utf-8")

    assert "--output-format json" in text
    assert "notary-submission.json" in text
    assert "notary-log.json" in text
    assert "notary-submission-id" in text
    assert "notary-submitted-pkg.sha256" in text

    # --- scenario: package_builder_embeds_reviewed_sparkle_before_signing
    text = BUILD_SCRIPT.read_text(encoding="utf-8")

    prepare = 'scripts/prepare_sparkle.py" --output "$SPARKLE_DISTRIBUTION"'
    embed = '"$SPARKLE_DISTRIBUTION/Sparkle.framework"'
    license_copy = 'Contents/Resources/ThirdPartyLicenses/Sparkle.txt'
    sign = 'packaging/sign_macos_app.py"'
    verify = 'packaging/verify_sparkle_bundle.py"'

    assert prepare in text
    assert 'SPARKLE_ARCHIVE="${SPARKLE_ARCHIVE:-}"' in text
    assert embed in text
    assert license_copy in text
    assert 'packaging/sparkle_public_ed_key.txt' in text
    assert text.index(prepare) < text.index(embed) < text.index(sign) < text.index(verify)

    # --- scenario: package_builder_writes_only_reviewed_sparkle_info_keys
    text = BUILD_SCRIPT.read_text(encoding="utf-8")

    for key in (
        "SUFeedURL",
        "SUPublicEDKey",
        "SURequireSignedFeed",
        "SUVerifyUpdateBeforeExtraction",
    ):
        assert f":{key}" in text
    for forbidden in (
        "SUEnableAutomaticChecks",
        "SUEnableInstallerLauncherService",
        "SUEnableDownloaderService",
        "com.apple.security.temporary-exception.mach-lookup.global-name",
    ):
        assert forbidden not in text
    assert 'packaging/entitlements.plist"' in text



def test_production_builder_notarizes_app_before_final_zip_and_pkg__and_2_more() -> None:
    # --- scenario: production_builder_notarizes_app_before_final_zip_and_pkg
    text = BUILD_SCRIPT.read_text(encoding="utf-8")

    app_submit = 'notarytool submit "$APP_NOTARY_ZIP"'
    app_staple = 'stapler staple "$APP_PATH"'
    app_validate = 'stapler validate "$APP_PATH"'
    updater_zip = 'scripts/package_sparkle_archive.py"'
    package = 'scripts/package_macos_artifact.py"'
    pkg_submit = 'notarytool submit "$OUTPUT_PKG"'

    assert "app-notary-submission.json" in text
    assert "app-notary-log.json" in text
    assert "app-notary-submitted-zip.sha256" in text
    assert 'OUTPUT_ZIP="$(contract updater-path)"' in text
    assert text.index(app_submit) < text.index(app_staple) < text.index(app_validate)
    assert text.index(app_validate) < text.index(updater_zip) < text.index(package)
    assert text.index(package) < text.index(pkg_submit)

    # --- scenario: unsigned_builder_explicitly_refuses_updater_evidence_claims
    text = BUILD_SCRIPT.read_text(encoding="utf-8")

    assert "ALLOW_UNSIGNED is local-only" in text
    assert "This package is not a production update candidate" in text
    # The appcast is signed only with the committed key's private half in
    # the keychain; every other outcome says so instead of shipping a feed.
    assert "appcast not signed" in text
    assert 'generate_keys" --account "$account" -p' in text
    assert "generate_sparkle_channel.py" in text
    assert "SPARKLE_PRIVATE_KEY" not in text

    # --- scenario: clean_install_verifies_t3_integration_artifacts_and_commands
    text = (ROOT / "scripts" / "verify_clean_install.py").read_text(encoding="utf-8")

    assert '"integration_compatibility.json"' in text
    assert '"jrbar-integrations"' in text
    assert '"integrations", "status", "--json"' in text
    assert '"jrbar.t3_compat"' in text
    assert "jrbar.codexbar_compat" not in text



def test_hook_ingress_benchmark_has_bounded_content_free_report_contract__and_1_more() -> None:
    # --- scenario: hook_ingress_benchmark_has_bounded_content_free_report_contract
    text = HOOK_BENCHMARK.read_text(encoding="utf-8")

    assert "MINIMUM_SAMPLES: Final = 50" in text
    assert 'choices=("both", "server-up", "server-down")' in text
    assert "TemporaryDirectory" in text
    for field in (
        "sample_count",
        "median_ms",
        "p95_ms",
        "accepted",
        "refused",
        "failed",
        "fallback",
    ):
        assert f'"{field}"' in text
    for forbidden in ("prompt_text", "tool_input", "tool_output", "raw_payload"):
        assert forbidden not in text

    # --- scenario: hook_ingress_benchmark_refuses_too_few_samples
    result = subprocess.run(
        [sys.executable, str(HOOK_BENCHMARK), "--samples", "49"],
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )

    assert result.returncode != 0
    assert "at least 50" in result.stderr



def test_package_builder_leaves_no_registered_jrbar_copy__and_1_more() -> None:
    # --- scenario: package_builder_unregisters_its_intermediate_bundles
    # Launch Services registers the bundles a build leaves behind, and any of
    # them can win a jrbar:// link; the one JR-Bar is ~/Applications'.
    text = BUILD_SCRIPT.read_text(encoding="utf-8")

    assert f'LSREGISTER_TOOL="${{LSREGISTER_TOOL:-{LSREGISTER}}}"' in text
    function = text.index("unregister_build_copies() {")
    unregister = text.index('"$LSREGISTER_TOOL" -u "$bundle" >/dev/null 2>&1 || true')
    trap = text.index("trap unregister_build_copies EXIT")
    assert function < text.index('for bundle in "$APP_PATH" "$SWIFT_APP"; do') < unregister < trap
    # Guarded, and armed on every exit once the build directory is made,
    # before the first JR-Bar.app exists: a failed notary or appcast step
    # leaves the same copies behind as a made package.
    assert function < text.index('if [ -x "$LSREGISTER_TOOL" ]; then') < unregister
    assert text.index('/bin/mkdir -p "$BUILD_DIR" "$DIST_DIR"') < trap
    assert trap < text.index('JRBAR_BUNDLE="$SWIFT_APP"')
    assert text.count("\ntrap ") == 1

    # --- scenario: pkg_install_registers_the_home_applications_copy
    text = INSTALL_SCRIPT.read_text(encoding="utf-8")
    pkg_branch = text[text.index('if [[ "$MODE" == "pkg" ]]; then'):text.index("    exit 0\nfi\n")]

    assert f'LSREGISTER="${{LSREGISTER_TOOL:-{LSREGISTER}}}"' in text
    assert 'if [[ -x "$LSREGISTER" ]]; then' in pkg_branch
    register = pkg_branch.index('if "$LSREGISTER" -f "$APP" >/dev/null 2>&1; then')
    # After the install is verified, before the app is launched.
    assert pkg_branch.index('codesign --verify --deep --strict "$APP"') < register
    assert register < pkg_branch.index('open -a "$APP"')
    # A refusal is said, never fatal.
    assert "jrbar:// links may open another copy" in pkg_branch
