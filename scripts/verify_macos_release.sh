#!/bin/bash
# The authoritative JR-Bar macOS release gate.
#
# It builds the 0.8 bundle with packaging/build_macos_pkg.sh and then proves,
# with a receipt per claim, that the thing on disk is the thing that will be
# published:
#
#   build/macos-pkg/swift/JR-Bar.app   the Swift build (input)
#   build/macos-pkg/app/JR-Bar.app     the assembled, signed candidate
#     Contents/Helpers/jrbar-core.app  the frozen Python daemon
#     Contents/Helpers/jrbar-hook      the compiled hook shim
#   dist/JR-Bar-<version>.pkg          the authoritative artifact
#   dist/JR-Bar-<version>.zip          the Sparkle archive
#   dist/appcast.xml, dist/jr-bar-update-channel.json
#
# CAPABILITIES ARE DISCOVERED, NOT DEMANDED. The gate looks in the keychain
# for the Developer ID Application identity (required), the Developer ID
# Installer identity, the notary keychain profile and the Sparkle signing
# account. Whatever is missing turns its phases into a printed SKIP with the
# reason, and the run finishes as a verified-but-not-publishable candidate.
# The moment the profile or identity appears, those phases run again with no
# edit here. Only a run that verified every phase prints the authoritative
# line and writes dist/release-verification.json.
#
# Modes:
#   (no flags)      authoritative: clean tree at freshly fetched origin/main
#   --preflight     print what would run and what would be skipped; no build
#   --reuse-build   verify the artifacts already in build/ and dist/
#   --skip-install  leave the installed app on this Mac alone
#
# Environment:
#   APP_SIGN_IDENTITY        override the Developer ID Application identity
#   INSTALLER_SIGN_IDENTITY  override the Developer ID Installer identity
#   NOTARY_PROFILE           notarytool keychain profile (default jrbar-notary)
#   SPARKLE_KEY_ACCOUNT      keychain account holding the Sparkle private key
#   JRBAR_PERFORMANCE_EVIDENCE  measured performance JSON (skips when unset)
#   JRBAR_REQUIRED_HARDWARE  software (default), any, pro, dot, both
#   JRBAR_HARDWARE_CONFIRM=1 authorize reversible hardware writes
#   JRBAR_INSTALL_SCOPE      home (default, ~/Applications, no password)
#                            or system (/Applications, needs sudo)
#   JRBAR_RUN_UNINSTALL=1    authorize the uninstall/reinstall phases
#   JRBAR_RELEASE_CHANNEL    stable (default) or beta
#   JRBAR_SPARKLE_HISTORY_DIR  retained previous appcast.xml and archives
#   JRBAR_SETTINGS_PATH      default ~/.config/jrbar/settings.json
#   JRBAR_RELEASE_USER       default the current login name
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON="${PYTHON:-$ROOT_DIR/.venv/bin/python}"
PERFORMANCE_SOURCE="${JRBAR_PERFORMANCE_EVIDENCE:-}"
REQUIRED_HARDWARE="${JRBAR_REQUIRED_HARDWARE:-software}"
SETTINGS_PATH="${JRBAR_SETTINGS_PATH:-$HOME/.config/jrbar/settings.json}"
RELEASE_USER="${JRBAR_RELEASE_USER:-$(/usr/bin/id -un)}"
EVIDENCE_DIR="$ROOT_DIR/dist/release-evidence"
PERFORMANCE_EVIDENCE="$ROOT_DIR/dist/performance-evidence.json"
RELEASE_CHANNEL="${JRBAR_RELEASE_CHANNEL:-stable}"
SPARKLE_HISTORY_DIR="${JRBAR_SPARKLE_HISTORY_DIR:-}"
INSTALL_SCOPE="${JRBAR_INSTALL_SCOPE:-home}"
NOTARY_PROFILE="${NOTARY_PROFILE:-jrbar-notary}"
BUILD_DIR="$ROOT_DIR/build/macos-pkg"
SWIFT_APP="$BUILD_DIR/swift/JR-Bar.app"
APP="$BUILD_DIR/app/JR-Bar.app"
CORE_HELPER="Contents/Helpers/jrbar-core.app"
CORE_HELPER_BINARY="$CORE_HELPER/Contents/MacOS/jrbar-core"
HOOK_HELPER="Contents/Helpers/jrbar-hook"
BUNDLE_IDENTIFIER="com.jonathanreed.jrbar"
# Overridable seams, matching packaging/build_macos_pkg.sh, so the contract
# test can drive the whole script without touching the real keychain.
SECURITY_TOOL="${SECURITY_TOOL:-/usr/bin/security}"
XCRUN_TOOL="${XCRUN_TOOL:-/usr/bin/xcrun}"

MODE="authoritative"
RUN_BUILD=1
RUN_INSTALL=1
while [ "$#" -gt 0 ]; do
    case "$1" in
        --preflight) MODE="preflight"; RUN_BUILD=0; RUN_INSTALL=0 ;;
        --reuse-build) MODE="reuse-build"; RUN_BUILD=0 ;;
        --skip-install) RUN_INSTALL=0 ;;
        -h|--help) /usr/bin/sed -n '2,45p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

skipped=()
skip() {
    skipped+=("$1")
    printf 'SKIP  %s: %s\n' "$1" "$2"
}
phase() { printf '\n==> %s\n' "$1"; }

if [ "$(uname -s)" != "Darwin" ]; then
    echo "The authoritative JR-Bar release gate requires macOS." >&2
    exit 2
fi
if [ ! -x "$PYTHON" ]; then
    echo "Missing development environment. Run ./scripts/bootstrap-dev.sh." >&2
    exit 2
fi
case "$RELEASE_CHANNEL" in
    stable|beta) ;;
    *) echo "JRBAR_RELEASE_CHANNEL must be stable or beta." >&2; exit 2 ;;
esac
case "$INSTALL_SCOPE" in
    home|system) ;;
    *) echo "JRBAR_INSTALL_SCOPE must be home or system." >&2; exit 2 ;;
esac
case "$REQUIRED_HARDWARE" in
    software) ;;
    any|pro|dot|both)
        if [ "${JRBAR_HARDWARE_CONFIRM:-0}" != "1" ]; then
            echo "Set JRBAR_HARDWARE_CONFIRM=1 to authorize reversible hardware writes." >&2
            exit 2
        fi
        ;;
    *) echo "JRBAR_REQUIRED_HARDWARE must be software, any, pro, dot, or both." >&2; exit 2 ;;
esac
if [ "$RELEASE_USER" != "$(/usr/bin/id -un)" ]; then
    echo "Run the release gate while logged in as JRBAR_RELEASE_USER." >&2
    exit 2
fi

cd "$ROOT_DIR"

# ---------------------------------------------------------------- capabilities
# Everything the keychain can answer, before anything expensive happens.
if [ -z "${APP_SIGN_IDENTITY:-}" ]; then
    APP_SIGN_IDENTITY="$("$SECURITY_TOOL" find-identity -v -p codesigning 2>/dev/null \
        | /usr/bin/sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | /usr/bin/head -1)"
fi
if [ -z "$APP_SIGN_IDENTITY" ]; then
    echo "No 'Developer ID Application' identity in the keychain." >&2
    echo "A release candidate must be Developer ID signed; ad-hoc and local" >&2
    echo "identities are for ./packaging/build_macos_pkg.sh, not for this gate." >&2
    exit 2
fi
if [ -z "${INSTALLER_SIGN_IDENTITY:-}" ]; then
    INSTALLER_SIGN_IDENTITY="$("$SECURITY_TOOL" find-identity -v 2>/dev/null \
        | /usr/bin/sed -n 's/.*"\(Developer ID Installer: [^"]*\)".*/\1/p' | /usr/bin/head -1)"
fi
INSTALLER_SIGNED=0
INSTALLER_REASON="no 'Developer ID Installer' identity in the keychain"
if [ -n "$INSTALLER_SIGN_IDENTITY" ]; then
    INSTALLER_SIGNED=1
    INSTALLER_REASON=""
fi
NOTARIZED=0
NOTARY_REASON="no '$NOTARY_PROFILE' notarytool keychain profile (xcrun notarytool store-credentials)"
if "$XCRUN_TOOL" notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    NOTARIZED=1
    NOTARY_REASON=""
fi

# The Sparkle account can only be probed once a Sparkle distribution exists.
SPARKLE_DISTRIBUTION="$BUILD_DIR/sparkle-distribution"
SPARKLE_PUBLIC_ED_KEY="$(/bin/cat "$ROOT_DIR/packaging/sparkle_public_ed_key.txt" 2>/dev/null | /usr/bin/tr -d '[:space:]' || true)"
resolve_sparkle_account() {
    local account
    APPCAST_SIGNED=0
    APPCAST_REASON="no keychain account holds the Sparkle private key for $SPARKLE_PUBLIC_ED_KEY"
    if [ ! -x "$SPARKLE_DISTRIBUTION/bin/generate_keys" ]; then
        APPCAST_REASON="no Sparkle distribution at $SPARKLE_DISTRIBUTION (build first)"
        return 0
    fi
    for account in "${SPARKLE_KEY_ACCOUNT:-}" ed25519 io.jrbar.app com.jonathanreed.jrbar; do
        [ -n "$account" ] || continue
        if [ "$("$SPARKLE_DISTRIBUTION/bin/generate_keys" --account "$account" -p 2>/dev/null || true)" = "$SPARKLE_PUBLIC_ED_KEY" ]; then
            SPARKLE_KEY_ACCOUNT="$account"
            APPCAST_SIGNED=1
            APPCAST_REASON=""
            return 0
        fi
    done
}
resolve_sparkle_account

PERFORMANCE_READY=0
PERFORMANCE_REASON="JRBAR_PERFORMANCE_EVIDENCE is unset (measure with Instruments first)"
if [ -n "$PERFORMANCE_SOURCE" ]; then
    if [ -f "$PERFORMANCE_SOURCE" ]; then
        PERFORMANCE_READY=1
        PERFORMANCE_REASON=""
    else
        PERFORMANCE_REASON="JRBAR_PERFORMANCE_EVIDENCE does not exist: $PERFORMANCE_SOURCE"
    fi
fi

if [ "$INSTALL_SCOPE" = "system" ]; then
    INSTALLED_APP="/Applications/JR-Bar.app"
    INSTALLER_TARGET="/"
    PKGUTIL_VOLUME=("--volume" "/")
else
    # ~/Applications is the reviewed default: the product archive enables
    # currentUserHome, so the install needs no administrator password and no
    # sudo prompt can stall an otherwise unattended gate.
    INSTALLED_APP="$HOME/Applications/JR-Bar.app"
    INSTALLER_TARGET="CurrentUserHomeDirectory"
    PKGUTIL_VOLUME=("--volume" "$HOME")
fi

printf 'JR-Bar release gate (%s)\n' "$MODE"
printf '  app signing:  %s\n' "$APP_SIGN_IDENTITY"
if [ "$INSTALLER_SIGNED" = "1" ]; then
    printf '  installer:    %s\n' "$INSTALLER_SIGN_IDENTITY"
else
    printf '  installer:    UNSIGNED (%s)\n' "$INSTALLER_REASON"
fi
if [ "$NOTARIZED" = "1" ]; then
    printf '  notarization: keychain profile %s\n' "$NOTARY_PROFILE"
else
    printf '  notarization: NOT NOTARIZED (%s)\n' "$NOTARY_REASON"
fi
if [ "$APPCAST_SIGNED" = "1" ]; then
    printf '  appcast:      signed by keychain account %s\n' "$SPARKLE_KEY_ACCOUNT"
else
    printf '  appcast:      UNSIGNED (%s)\n' "$APPCAST_REASON"
fi
if [ "$PERFORMANCE_READY" = "1" ]; then
    printf '  performance:  %s\n' "$PERFORMANCE_SOURCE"
else
    printf '  performance:  NOT MEASURED (%s)\n' "$PERFORMANCE_REASON"
fi
printf '  hardware:     %s\n' "$REQUIRED_HARDWARE"
printf '  install:      %s (%s)\n' "$INSTALLED_APP" "$INSTALL_SCOPE"
printf '  channel:      %s\n' "$RELEASE_CHANNEL"

PUBLISHABLE=1
for ready in "$INSTALLER_SIGNED" "$NOTARIZED" "$APPCAST_SIGNED" "$PERFORMANCE_READY"; do
    [ "$ready" = "1" ] || PUBLISHABLE=0
done
if [ "$MODE" != "authoritative" ]; then
    PUBLISHABLE=0
fi

if [ "$MODE" = "preflight" ]; then
    echo
    if [ "$PUBLISHABLE" = "1" ]; then
        echo "Preflight: every capability is present. A full run can publish."
    else
        echo "Preflight: this Mac can verify the candidate but not publish it."
        [ "$INSTALLER_SIGNED" = "1" ] || echo "  - PKG signature and PKG Gatekeeper: $INSTALLER_REASON"
        [ "$NOTARIZED" = "1" ] || echo "  - notarization, stapling and app Gatekeeper: $NOTARY_REASON"
        [ "$APPCAST_SIGNED" = "1" ] || echo "  - signed appcast and channel metadata: $APPCAST_REASON"
        [ "$PERFORMANCE_READY" = "1" ] || echo "  - performance budget: $PERFORMANCE_REASON"
    fi
    exit 0
fi

# ------------------------------------------------------------- release commit
# The authoritative run may only describe a commit the world can fetch.
if [ "$MODE" = "authoritative" ]; then
    if [ -n "$(git status --porcelain --untracked-files=all)" ]; then
        echo "Refusing release verification from a dirty or untracked tree." >&2
        exit 2
    fi
    git fetch --quiet origin main --tags
    head_commit="$(git rev-parse HEAD)"
    origin_main_commit="$(git rev-parse origin/main)"
    current_branch="$(git branch --show-current)"
    if [ -n "$current_branch" ] && [ "$current_branch" != "main" ]; then
        echo "Authoritative release verification must run from main or its detached commit." >&2
        exit 2
    fi
    if [ "$head_commit" != "$origin_main_commit" ]; then
        echo "Release commit is not exactly the freshly fetched origin/main." >&2
        exit 2
    fi
else
    head_commit="$(git rev-parse HEAD)"
    echo
    echo "NOT AN AUTHORITATIVE RELEASE RUN: --$MODE does not check the release commit."
fi

# -------------------------------------------------------------------- packaging
if [ "$RUN_BUILD" = "1" ]; then
    phase "packaging/build_macos_pkg.sh"
    APP_SIGN_IDENTITY="$APP_SIGN_IDENTITY" \
    INSTALLER_SIGN_IDENTITY="$INSTALLER_SIGN_IDENTITY" \
    NOTARY_PROFILE="$NOTARY_PROFILE" \
    SPARKLE_KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-}" \
    JRBAR_RELEASE_CHANNEL="$RELEASE_CHANNEL" \
    JRBAR_SPARKLE_HISTORY_DIR="$SPARKLE_HISTORY_DIR" \
        ./packaging/build_macos_pkg.sh
    resolve_sparkle_account
else
    skip packaging "--$MODE reuses the artifacts already in build/ and dist/"
fi

version="$("$PYTHON" scripts/validate_release_version.py)"
arch="$(/usr/bin/uname -m)"
contract() {
    "$PYTHON" scripts/release_artifact_contract.py \
        --version "$version" \
        --architecture "$arch" \
        --dist-dir "$ROOT_DIR/dist" \
        --format "$1"
}
pkg="$(contract path)"
update_archive="$(contract updater-path)"
appcast="$(contract appcast-path)"
channel_metadata="$(contract channel-metadata-path)"
developer_artifacts=()
while IFS= read -r artifact; do
    if [ -n "$artifact" ]; then
        developer_artifacts+=("$artifact")
    fi
done <<< "$(contract developer-paths)"
if [ "${#developer_artifacts[@]}" -ne 2 ]; then
    echo "Release artifact contract did not return one wheel and one sdist." >&2
    exit 1
fi
# The wheel and sdist are developer artifacts, built from the same checkout.
# A fresh build wipes build/macos-pkg; --reuse-build has to clear the staging
# directory itself, because the builder refuses a dirty one.
/bin/rm -rf "$BUILD_DIR/python-release"
"$PYTHON" scripts/python_release_artifacts.py \
    --root "$ROOT_DIR" \
    --staging-dir "$BUILD_DIR/python-release" \
    --output-dir "$ROOT_DIR/dist" \
    --version "$version"

environment_snapshot="$ROOT_DIR/dist/release-environment.txt"
raw_evidence_dir="$BUILD_DIR/release-evidence-raw"
notary_response="$raw_evidence_dir/notary-submission.json"
notary_log="$raw_evidence_dir/notary-log.json"
notary_submitted_sha="$raw_evidence_dir/notary-submitted-pkg.sha256"
app_notary_response="$raw_evidence_dir/app-notary-submission.json"
app_notary_log="$raw_evidence_dir/app-notary-log.json"
app_notary_submitted_sha="$raw_evidence_dir/app-notary-submitted-zip.sha256"

# -------------------------------------------------------------- the bundle itself
phase "candidate bundle $APP"
for required in "$pkg" "$update_archive" "$environment_snapshot"; do
    if [ ! -f "$required" ]; then
        echo "Release artifact is missing: $required" >&2
        exit 1
    fi
done
for required_dir in "$APP" "$SWIFT_APP" "$SPARKLE_DISTRIBUTION"; do
    if [ ! -d "$required_dir" ]; then
        echo "Build output is missing: $required_dir" >&2
        exit 1
    fi
done
# 0.8 ships three programs in one bundle. All three have to be there, be
# executable, and be sealed by the outer signature; a candidate missing the
# daemon or the shim installs cleanly and then does nothing.
for helper in "$CORE_HELPER_BINARY" "$HOOK_HELPER"; do
    if [ ! -x "$APP/$helper" ]; then
        echo "Candidate bundle carries no executable $helper." >&2
        exit 1
    fi
done
if [ ! -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
    echo "Candidate bundle carries no embedded Sparkle.framework." >&2
    exit 1
fi

expected_team="$(/usr/bin/codesign -dv --verbose=4 "$APP" 2>&1 \
    | /usr/bin/awk -F= '/^TeamIdentifier=/ {print $2}')"
if [ -z "$expected_team" ] || [ "$expected_team" = "not set" ]; then
    echo "Signed candidate has no TeamIdentifier." >&2
    exit 1
fi
echo "team $expected_team, version $version, commit $head_commit"

# ------------------------------------------------------------------- evidence
case "$EVIDENCE_DIR" in
    "$ROOT_DIR"/dist/release-evidence) ;;
    *) echo "Refusing unsafe release evidence directory: $EVIDENCE_DIR" >&2; exit 2 ;;
esac
/bin/rm -rf "$EVIDENCE_DIR"
/bin/mkdir -m 700 "$EVIDENCE_DIR"
if [ "$PERFORMANCE_READY" = "1" ]; then
    /bin/cp "$PERFORMANCE_SOURCE" "$PERFORMANCE_EVIDENCE"
    /bin/chmod 644 "$PERFORMANCE_EVIDENCE"
fi

candidate="$EVIDENCE_DIR/candidate.json"
"$PYTHON" scripts/release_evidence.py candidate \
    --root "$ROOT_DIR" \
    --output "$candidate" \
    --version "$version" \
    --architecture "$arch" \
    --commit "$head_commit" \
    --pkg "$pkg" \
    --app "$APP" \
    --update-archive "$update_archive" \
    --bundle-identifier "$BUNDLE_IDENTIFIER" \
    --team-identifier "$expected_team"
candidate_id="$("$PYTHON" -c \
    'import json,sys; value=json.load(open(sys.argv[1], encoding="utf-8")); print(value["candidate_id"])' \
    "$candidate")"

receipt_files=()
record_receipt() {
    local kind="$1"
    local input="$2"
    local output="$EVIDENCE_DIR/$kind.json"
    shift 2
    "$PYTHON" scripts/release_evidence.py run-receipt \
        --root "$ROOT_DIR" \
        --candidate "$candidate" \
        --kind "$kind" \
        --input "$input" \
        --output "$output" \
        -- "$@"
    receipt_files+=("$output")
}

# ----------------------------------------------------------------- the appcast
phase "signed Sparkle appcast"
if [ "$APPCAST_SIGNED" = "1" ]; then
    sparkle_channel_args=(
        --sparkle-distribution "$SPARKLE_DISTRIBUTION"
        --archive "$update_archive"
        --output-dir "$ROOT_DIR/dist"
        --candidate-id "$candidate_id"
        --keychain-account "$SPARKLE_KEY_ACCOUNT"
        --channel "$RELEASE_CHANNEL"
    )
    if [ -n "$SPARKLE_HISTORY_DIR" ]; then
        case "$SPARKLE_HISTORY_DIR" in
            /*) ;;
            *) echo "JRBAR_SPARKLE_HISTORY_DIR must be an absolute path." >&2; exit 2 ;;
        esac
        if [ ! -d "$SPARKLE_HISTORY_DIR" ] || [ ! -f "$SPARKLE_HISTORY_DIR/appcast.xml" ]; then
            echo "Sparkle history must contain appcast.xml: $SPARKLE_HISTORY_DIR" >&2
            exit 2
        fi
        sparkle_channel_args+=(--previous-appcast "$SPARKLE_HISTORY_DIR/appcast.xml")
        previous_archive_count=0
        while IFS= read -r -d '' previous_archive; do
            sparkle_channel_args+=(--previous-archive "$previous_archive")
            previous_archive_count=$((previous_archive_count + 1))
        done < <(/usr/bin/find "$SPARKLE_HISTORY_DIR" -maxdepth 1 -type f -name 'JR-Bar-*.zip' -print0)
        if [ "$previous_archive_count" -eq 0 ]; then
            echo "Sparkle history contains no retained JR-Bar update archive." >&2
            exit 2
        fi
    fi
    "$PYTHON" scripts/generate_sparkle_channel.py "${sparkle_channel_args[@]}"
    if [ ! -f "$appcast" ] || [ ! -f "$channel_metadata" ]; then
        echo "Signed Sparkle appcast or candidate-bound channel metadata is missing." >&2
        exit 1
    fi
else
    skip signed-appcast "$APPCAST_REASON"
fi

# ------------------------------------------------------------------- receipts
phase "source gate"
record_receipt source-gate "$pkg" ./scripts/verify.sh --no-bootstrap --skip-build --skip-clean-install

phase "performance budget"
if [ "$PERFORMANCE_READY" = "1" ]; then
    record_receipt performance "$PERFORMANCE_EVIDENCE" \
        "$PYTHON" scripts/verify_performance_budget.py "$PERFORMANCE_EVIDENCE"
else
    skip performance "$PERFORMANCE_REASON"
fi

phase "application signature and sealed helpers"
# codesign --deep validates the nested jrbar-core.app; the explicit per-helper
# checks prove the daemon and the shim are themselves signed by the same team
# and are not merely unsigned data files sitting inside a signed wrapper.
record_receipt app-signature "$APP" /bin/bash -c '
set -euo pipefail
app="$1"
team="$2"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"
for helper in Contents/Helpers/jrbar-core.app Contents/Helpers/jrbar-hook; do
    /usr/bin/codesign --verify --strict --verbose=2 "$app/$helper"
    helper_team="$(/usr/bin/codesign -dv --verbose=4 "$app/$helper" 2>&1 \
        | /usr/bin/awk -F= "/^TeamIdentifier=/ {print \$2}")"
    if [ "$helper_team" != "$team" ]; then
        echo "$helper is signed by $helper_team, not $team" >&2
        exit 1
    fi
    echo "$helper: sealed, team $helper_team"
done
' app-signature "$APP" "$expected_team"

phase "application Gatekeeper"
if [ "$NOTARIZED" = "1" ]; then
    record_receipt app-gatekeeper "$APP" /usr/sbin/spctl -a -vv "$APP"
else
    # spctl rejects a Developer ID bundle that has not been notarized. That is
    # a fact about the ticket, not about the candidate.
    skip app-gatekeeper "$NOTARY_REASON; spctl would report 'Unnotarized Developer ID'"
fi

phase "bundle closure and entitlements"
record_receipt bundle-closure "$APP" "$PYTHON" packaging/verify_macos_app.py "$APP"
record_receipt entitlements "$APP" "$PYTHON" packaging/verify_entitlements.py "$APP"
record_receipt sparkle-nested-signing "$APP" \
    "$PYTHON" packaging/verify_sparkle_bundle.py "$APP" \
        --production --expected-team "$expected_team"

phase "package signature and Gatekeeper"
if [ "$INSTALLER_SIGNED" = "1" ]; then
    record_receipt pkg-signature "$pkg" /usr/sbin/pkgutil --check-signature "$pkg"
else
    skip pkg-signature "$INSTALLER_REASON; pkgutil reports 'Status: no signature'"
fi
if [ "$INSTALLER_SIGNED" = "1" ] && [ "$NOTARIZED" = "1" ]; then
    record_receipt pkg-gatekeeper "$pkg" /usr/sbin/spctl -a -vv -t install "$pkg"
else
    skip pkg-gatekeeper "an unsigned or unnotarized PKG has no usable installer signature"
fi
package_contents_receipt="$EVIDENCE_DIR/package-contents.json"
"$PYTHON" scripts/release_evidence.py package-contents-receipt \
    --root "$ROOT_DIR" \
    --candidate "$candidate" \
    --pkg "$pkg" \
    --output "$package_contents_receipt"
receipt_files+=("$package_contents_receipt")

phase "notarization and stapling"
if [ "$NOTARIZED" = "1" ]; then
    for required_notary_file in \
        "$app_notary_response" "$app_notary_log" "$app_notary_submitted_sha"; do
        if [ ! -f "$required_notary_file" ]; then
            echo "Notarization evidence is missing: $required_notary_file" >&2
            exit 1
        fi
    done
    app_notarization_receipt="$EVIDENCE_DIR/app-notarization.json"
    "$PYTHON" scripts/release_evidence.py app-notarization-receipt \
        --root "$ROOT_DIR" --candidate "$candidate" --app "$APP" \
        --response "$app_notary_response" --log "$app_notary_log" \
        --submitted-sha256 "$app_notary_submitted_sha" \
        --output "$app_notarization_receipt"
    receipt_files+=("$app_notarization_receipt")
    app_stapling_receipt="$EVIDENCE_DIR/app-stapling.json"
    "$PYTHON" scripts/release_evidence.py app-stapling-receipt \
        --root "$ROOT_DIR" --candidate "$candidate" --app "$APP" \
        --response "$app_notary_response" \
        --output "$app_stapling_receipt"
    receipt_files+=("$app_stapling_receipt")
else
    skip app-notarization "$NOTARY_REASON"
    skip app-stapling "$NOTARY_REASON"
fi
if [ "$NOTARIZED" = "1" ] && [ "$INSTALLER_SIGNED" = "1" ]; then
    for required_notary_file in \
        "$notary_response" "$notary_log" "$notary_submitted_sha"; do
        if [ ! -f "$required_notary_file" ]; then
            echo "Notarization evidence is missing: $required_notary_file" >&2
            exit 1
        fi
    done
    notarization_receipt="$EVIDENCE_DIR/notarization.json"
    "$PYTHON" scripts/release_evidence.py notarization-receipt \
        --root "$ROOT_DIR" --candidate "$candidate" --pkg "$pkg" \
        --response "$notary_response" --log "$notary_log" \
        --submitted-sha256 "$notary_submitted_sha" \
        --output "$notarization_receipt"
    receipt_files+=("$notarization_receipt")
    stapling_receipt="$EVIDENCE_DIR/stapling.json"
    "$PYTHON" scripts/release_evidence.py stapling-receipt \
        --root "$ROOT_DIR" --candidate "$candidate" --pkg "$pkg" \
        --submitted-sha256 "$notary_submitted_sha" \
        --output "$stapling_receipt"
    receipt_files+=("$stapling_receipt")
else
    skip notarization "an unsigned PKG cannot be notarized"
    skip stapling "an unsigned PKG carries no notarization ticket to staple"
fi

phase "update archive and appcast"
record_receipt update-archive "$update_archive" \
    "$PYTHON" -c \
    'import sys; from pathlib import Path; from scripts.package_sparkle_archive import validate_archive; validate_archive(archive=Path(sys.argv[1]), app=Path(sys.argv[2]))' \
    "$update_archive" "$APP"
if [ "$APPCAST_SIGNED" = "1" ]; then
    record_receipt signed-appcast "$appcast" \
        "$PYTHON" -c \
        'import sys; from pathlib import Path; from scripts.generate_sparkle_channel import validate_channel_outputs; validate_channel_outputs(archive=Path(sys.argv[1]), appcast=Path(sys.argv[2]), metadata=Path(sys.argv[3]), candidate_id=sys.argv[4], sparkle_distribution=Path(sys.argv[5]), keychain_account=sys.argv[6])' \
        "$update_archive" "$appcast" "$channel_metadata" "$candidate_id" \
        "$SPARKLE_DISTRIBUTION" "$SPARKLE_KEY_ACCOUNT"
fi

phase "hardware smoke"
if [ "$REQUIRED_HARDWARE" != "software" ]; then
    record_receipt hardware-smoke "$pkg" \
        "$PYTHON" scripts/verify_hardware_release.py \
            --confirm-write --require "$REQUIRED_HARDWARE"
else
    skip hardware-smoke "JRBAR_REQUIRED_HARDWARE is software; no device write was authorized"
fi

# --------------------------------------------------------------- installed app
# Everything below touches the JR-Bar installed on this Mac.
phase "installed upgrade at $INSTALLED_APP"
was_running=0
# A running JR-Bar owns its settings file and rewrites it as devices and
# sessions come and go. Installing underneath it would both be unrealistic
# (a real upgrade quits first) and make settings preservation unprovable:
# a field that changed between the snapshots would be indistinguishable
# from an installer that damaged it. So quit it, install, check, restore.
stop_app() {
    if /usr/bin/pgrep -x JR-Bar >/dev/null 2>&1; then
        was_running=1
        echo "quitting the running JR-Bar so the install can be observed"
        # Quitting stops the supervised daemon too, which takes a moment, and
        # an app still coming up may not be scriptable yet — so re-send the
        # quit every five seconds rather than trusting one Apple event.
        waited=0
        while /usr/bin/pgrep -x JR-Bar >/dev/null 2>&1 && [ "$waited" -lt 30 ]; do
            if [ $((waited % 5)) -eq 0 ]; then
                /usr/bin/osascript -e 'tell application "JR-Bar" to quit' >/dev/null 2>&1 || true
            fi
            /bin/sleep 1
            waited=$((waited + 1))
        done
        if /usr/bin/pgrep -x JR-Bar >/dev/null 2>&1; then
            echo "JR-Bar did not quit; refusing to install underneath it." >&2
            exit 1
        fi
    fi
}
start_app() {
    if [ "$was_running" = "1" ]; then
        echo "relaunching $INSTALLED_APP"
        /usr/bin/open -a "$INSTALLED_APP" || true
    fi
}
install_pkg() {
    if [ "$INSTALL_SCOPE" = "system" ]; then
        /usr/bin/sudo /usr/sbin/installer -pkg "$pkg" -target "$INSTALLER_TARGET"
    else
        /usr/sbin/installer -pkg "$pkg" -target "$INSTALLER_TARGET"
    fi
}
installed_version() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$INSTALLED_APP/Contents/Info.plist" 2>/dev/null || true
}
before_settings=""
cleanup() {
    [ -z "$before_settings" ] || /bin/rm -f "$before_settings"
}
trap cleanup EXIT

if [ "$RUN_INSTALL" != "1" ]; then
    skip installed-upgrade "--skip-install left the installed app alone"
    skip settings-preservation "--skip-install left the installed app alone"
    skip clean-install "--skip-install left the installed app alone"
    skip uninstall "--skip-install left the installed app alone"
elif [ ! -f "$SETTINGS_PATH" ]; then
    skip installed-upgrade "no settings to preserve at $SETTINGS_PATH"
    skip settings-preservation "no settings to preserve at $SETTINGS_PATH"
    skip clean-install "no settings to preserve at $SETTINGS_PATH"
    skip uninstall "no settings to preserve at $SETTINGS_PATH"
else
    previous_version="$(installed_version)"
    upgrade_baseline="$EVIDENCE_DIR/pre-upgrade-baseline.json"
    baseline_ready=0
    if [ -d "$INSTALLED_APP" ] && [ -n "$previous_version" ]; then
        if "$PYTHON" -c \
            'import sys; from scripts import release_evidence; release_evidence.require_strict_version_upgrade(sys.argv[1], sys.argv[2])' \
            "$previous_version" "$version" >/dev/null 2>&1; then
            baseline_ready=1
        fi
    fi
    stop_app
    before_settings="$(/usr/bin/mktemp -t jrbar-settings-before.XXXXXX.json)"
    /bin/cp "$SETTINGS_PATH" "$before_settings"

    if [ "$baseline_ready" = "1" ]; then
        "$PYTHON" scripts/capture_installed_release_baseline.py \
            --app "$INSTALLED_APP" \
            --settings "$SETTINGS_PATH" \
            --output "$upgrade_baseline" || baseline_ready=0
    fi

    install_pkg
    if [ ! -x "$INSTALLED_APP/Contents/MacOS/JR-Bar" ]; then
        echo "Installed JR-Bar executable is missing at $INSTALLED_APP." >&2
        exit 1
    fi

    if [ "$baseline_ready" = "1" ]; then
        record_receipt installed-upgrade "$pkg" \
            "$PYTHON" -c '
import sys
from pathlib import Path

from scripts import release_evidence

baseline = release_evidence.load_json_object(Path(sys.argv[1]), label="pre-upgrade baseline")
candidate = release_evidence.load_json_object(Path(sys.argv[2]), label="candidate")
app = Path(sys.argv[3])
team = sys.argv[4]
if baseline.get("schema_version") != 1:
    raise SystemExit("pre-upgrade baseline schema is unsupported")
for field, expected in (
    ("package_identifier", "com.jonathanreed.jrbar"),
    ("bundle_identifier", "com.jonathanreed.jrbar"),
    ("team_identifier", team),
):
    if baseline.get(field) != expected:
        raise SystemExit(f"pre-upgrade {field} changed: {baseline.get(field)!r}")
release_evidence.require_strict_version_upgrade(baseline["version"], candidate["version"])
installed = release_evidence.sha256_tree(app)
if installed != candidate["app"]["sha256"]:
    raise SystemExit("the upgraded app is not the exact candidate")
print(f"upgraded {baseline[\"version\"]} -> {candidate[\"version\"]}, tree {installed}")
' "$upgrade_baseline" "$candidate" "$INSTALLED_APP" "$expected_team"
    else
        skip installed-upgrade \
            "installed ${previous_version:-nothing} is not older than $version; there is no upgrade to observe"
    fi

    phase "settings preservation"
    record_receipt settings-preservation "$pkg" \
        "$PYTHON" -c '
import json
import sys

before = json.load(open(sys.argv[1], encoding="utf-8"))
after = json.load(open(sys.argv[2], encoding="utf-8"))
lost = sorted(
    key
    for key, value in before.items()
    if key != "settings_schema_version" and after.get(key, object()) != value
)
if lost:
    raise SystemExit("the install changed preserved settings: " + ", ".join(lost))
if not isinstance(after.get("settings_schema_version"), int):
    raise SystemExit("installed settings carry no schema version")
print(f"settings preserved: {len(before)} fields")
' "$before_settings" "$SETTINGS_PATH"

    # The 0.8 doctor lives in the bundled daemon, not in the Swift executable
    # (Contents/MacOS/JR-Bar takes no arguments; it opens the menu bar). This
    # runs the INSTALLED copy: it proves the shipped daemon starts, and that
    # every provider hook points at the shim inside THIS bundle rather than at
    # a developer checkout that will disappear.
    phase "installed doctor and clean install"
    record_receipt clean-install "$pkg" /bin/bash -c '
set -euo pipefail
app="$1"
team="$2"
identifier="$3"
python="$4"
candidate="$5"
shift 5
installed_identifier="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app/Contents/Info.plist")"
if [ "$installed_identifier" != "$identifier" ]; then
    echo "installed bundle identifier is $installed_identifier" >&2
    exit 1
fi
installed_team="$(/usr/bin/codesign -dv --verbose=4 "$app" 2>&1 \
    | /usr/bin/awk -F= "/^TeamIdentifier=/ {print \$2}")"
if [ "$installed_team" != "$team" ]; then
    echo "installed signing team is $installed_team" >&2
    exit 1
fi
/usr/bin/codesign --verify --deep --strict "$app"
/usr/sbin/pkgutil "$@" --pkg-info "$identifier"
for helper in Contents/Helpers/jrbar-core.app/Contents/MacOS/jrbar-core Contents/Helpers/jrbar-hook; do
    if [ ! -x "$app/$helper" ]; then
        echo "installed bundle has no $helper" >&2
        exit 1
    fi
done
"$python" -c "
import sys
from pathlib import Path
from scripts import release_evidence
candidate = release_evidence.load_json_object(Path(sys.argv[2]), label=\"candidate\")
installed = release_evidence.sha256_tree(Path(sys.argv[1]))
if installed != candidate[\"app\"][\"sha256\"]:
    raise SystemExit(\"the installed app is not the exact candidate\")
print(\"installed tree matches the candidate:\", installed)
" "$app" "$candidate"
core="$app/Contents/Helpers/jrbar-core.app/Contents/MacOS/jrbar-core"
"$core" doctor
hooks="$("$core" hooks doctor)"
printf "%s\n" "$hooks"
case "$hooks" in
    *"hook shim: $app/Contents/Helpers/jrbar-hook"*) ;;
    *) echo "the installed daemon does not use the bundled hook shim" >&2; exit 1 ;;
esac
echo "clean install verified"
' clean-install "$INSTALLED_APP" "$expected_team" "$BUNDLE_IDENTIFIER" \
    "$PYTHON" "$candidate" "${PKGUTIL_VOLUME[@]}"

    phase "uninstall"
    if [ "${JRBAR_RUN_UNINSTALL:-0}" != "1" ]; then
        skip uninstall "set JRBAR_RUN_UNINSTALL=1 to authorize removing and reinstalling JR-Bar"
    elif [ "$INSTALL_SCOPE" != "system" ]; then
        # scripts/uninstall-macos.sh insists on root because it also clears
        # /var/db receipts and the system eject guard. A home-scope run has
        # neither, so verifying it here would prove nothing about the
        # supported uninstaller.
        skip uninstall "the supported uninstaller is root-only; rerun with JRBAR_INSTALL_SCOPE=system"
    else
        before_uninstall_settings="$(/usr/bin/mktemp -t jrbar-settings-before-uninstall.XXXXXX.json)"
        /bin/cp "$SETTINGS_PATH" "$before_uninstall_settings"
        uninstall_log="$EVIDENCE_DIR/uninstall.log"
        if ! /usr/bin/sudo "$ROOT_DIR/scripts/uninstall-macos.sh" \
            --user "$RELEASE_USER" > "$uninstall_log" 2>&1; then
            /bin/cat "$uninstall_log" >&2
            exit 1
        fi
        /bin/cat "$uninstall_log"
        uninstall_receipt="$EVIDENCE_DIR/uninstall.json"
        "$PYTHON" scripts/verify_uninstalled_candidate.py \
            --root "$ROOT_DIR" \
            --candidate "$candidate" \
            --pkg "$pkg" \
            --app "$INSTALLED_APP" \
            --before-settings "$before_uninstall_settings" \
            --settings "$SETTINGS_PATH" \
            --user "$RELEASE_USER" \
            --output "$uninstall_receipt"
        receipt_files+=("$uninstall_receipt")
        /bin/rm -f "$before_uninstall_settings"
        install_pkg
    fi
    start_app
fi

# ------------------------------------------------------------------ SBOM
phase "SBOM"
artifacts=(
    "${developer_artifacts[@]}"
    "$environment_snapshot"
    "$pkg"
    "$update_archive"
)
if [ "$PERFORMANCE_READY" = "1" ]; then
    artifacts+=("$PERFORMANCE_EVIDENCE")
fi
if [ "$APPCAST_SIGNED" = "1" ]; then
    artifacts+=("$appcast" "$channel_metadata")
fi
sbom="$ROOT_DIR/dist/jrbar-sbom.cdx.json"
sbom_args=(--output "$sbom" --root "$ROOT_DIR" --application-version "$version")
for artifact in "${artifacts[@]}"; do
    sbom_args+=(--artifact "$artifact")
done
SOURCE_DATE_EPOCH="$(git show -s --format=%ct HEAD)" \
    "$PYTHON" scripts/generate_sbom.py "${sbom_args[@]}"
record_receipt sbom "$sbom" \
    "$PYTHON" -c \
    'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8")); assert d.get("bomFormat") == "CycloneDX"' \
    "$sbom"
artifacts+=("$sbom")

# -------------------------------------------------------------- the manifest
phase "release manifest"
if [ "$PUBLISHABLE" = "1" ] && [ "${#skipped[@]}" -eq 0 ]; then
    manifest_args=(
        --root "$ROOT_DIR"
        --output "$ROOT_DIR/dist/release-verification.json"
        --candidate "$candidate"
        --performance-evidence "$PERFORMANCE_EVIDENCE"
        --sbom "$sbom"
        --hardware-profile "$REQUIRED_HARDWARE"
    )
    for artifact in "${artifacts[@]}"; do
        manifest_args+=(--artifact "$artifact")
    done
    for receipt in "${receipt_files[@]}"; do
        manifest_args+=(--receipt "$receipt")
    done
    "$PYTHON" scripts/generate_release_manifest.py "${manifest_args[@]}"
else
    /bin/rm -f "$ROOT_DIR/dist/release-verification.json"
    skip release-manifest "the manifest is fail-closed: it needs every receipt kind"
fi

echo
printf 'JR-Bar %s (%s)\n' "$version" "$head_commit"
printf '  receipts: %s\n' "${#receipt_files[@]}"
if [ "${#skipped[@]}" -gt 0 ]; then
    printf '  skipped:  %s\n' "${skipped[*]}"
fi
echo
if [ "$PUBLISHABLE" = "1" ] && [ "${#skipped[@]}" -eq 0 ]; then
    printf '%s\n' "Authoritative JR-Bar macOS release gate passed."
    exit 0
fi
echo "This candidate was verified but is NOT publishable:"
[ "$INSTALLER_SIGNED" = "1" ] || echo "  - installer unsigned ($INSTALLER_REASON)"
[ "$NOTARIZED" = "1" ] || echo "  - not notarized ($NOTARY_REASON)"
[ "$APPCAST_SIGNED" = "1" ] || echo "  - appcast unsigned ($APPCAST_REASON)"
[ "$PERFORMANCE_READY" = "1" ] || echo "  - performance not measured ($PERFORMANCE_REASON)"
[ "$MODE" = "authoritative" ] || echo "  - --$MODE is a local diagnostic, not a release run"
echo
echo "Every check that could run passed. scripts/publish_release.sh refuses to"
echo "publish without dist/release-verification.json, so nothing can ship from"
echo "this run; see docs/PRODUCTION-RELEASE.md for what to install first."
exit 0
