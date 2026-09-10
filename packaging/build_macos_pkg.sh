#!/bin/bash
# Builds, signs, (optionally) notarizes and packages JR-Bar.app.
#
#   JR-Bar.app/Contents/MacOS/JR-Bar              the Swift app (app/, SwiftPM)
#   JR-Bar.app/Contents/Helpers/jrbar-core.app    the Python daemon (PyInstaller; run
#                                                 Contents/MacOS/jrbar-core inside it)
#   JR-Bar.app/Contents/Helpers/jrbar-hook        the compiled hook shim (hook/jrbar-hook.c)
#   JR-Bar.app/Contents/Frameworks/Sparkle.framework   pinned Sparkle 2.9.6
#
# The daemon is a nested .app rather than a bare onedir directory because
# codesign treats every entry of Contents/Helpers as nested code: a plain
# directory of Python files cannot be sealed, PyInstaller's bundle layout
# (binaries in Frameworks, data in Resources) can.
#
# Outputs (dist/): JR-Bar-<version>.pkg, JR-Bar-<version>.zip (the Sparkle
# archive), appcast.xml + jr-bar-update-channel.json (when the Sparkle key is
# in the keychain) and release-environment.txt.
#
# Signing picks the best identity in the keychain unless APP_SIGN_IDENTITY
# names one: "Developer ID Application" (hardened runtime, timestamp, and
# notarization when the NOTARY_PROFILE keychain profile exists), else
# "Nautilus Local Dev", else ad-hoc. The PKG is signed only when a
# "Developer ID Installer" identity exists. ALLOW_UNSIGNED=1 skips the
# keychain entirely (ad-hoc, no notarization): the local-only mode the
# contract tests run.
#
# External steps are behind overridable seams so the contract test can run
# the whole script with doubles: APP_BUILD_SCRIPT, HOOK_BUILD_SCRIPT,
# SECURITY_TOOL, CODESIGN_TOOL, XCRUN_TOOL, BUILD_PYTHON, BUILD_ROOT,
# OUTPUT_ROOT.
set -euo pipefail

ROOT_DIR="$(cd "$(/usr/bin/dirname "$0")/.." && /bin/pwd)"
ARCH="$(/usr/bin/uname -m)"
BUILD_DIR="${BUILD_ROOT:-$ROOT_DIR/build/macos-pkg}"
DIST_DIR="${OUTPUT_ROOT:-$ROOT_DIR/dist}"
RAW_EVIDENCE_DIR="$BUILD_DIR/release-evidence-raw"
SPARKLE_DISTRIBUTION="$BUILD_DIR/sparkle-distribution"
APP_NOTARY_ZIP="$BUILD_DIR/JR-Bar-app-notary.zip"
REQUESTED_BUILD_PYTHON="${BUILD_PYTHON:-}"
CONSTRAINTS="$ROOT_DIR/requirements/release-constraints.txt"
LOCKFILE="$ROOT_DIR/requirements/release-lock.txt"
PINNED_PIP="26.1.2"
PINNED_PYINSTALLER="6.21.0"
VENV_DIR="$BUILD_DIR/venv"
SWIFT_APP="$BUILD_DIR/swift/JR-Bar.app"
CORE_APP="$BUILD_DIR/pyinstaller/jrbar-core.app"
CORE_ID="com.jonathanreed.jrbar.core"
HOOK_DIR="$BUILD_DIR/hook"
APP_PATH="$BUILD_DIR/app/JR-Bar.app"
HELPERS="$APP_PATH/Contents/Helpers"
COMPONENT_PKG="$BUILD_DIR/JR-Bar-component.pkg"
ENVIRONMENT_SNAPSHOT="$DIST_DIR/release-environment.txt"
APP_ID="com.jonathanreed.jrbar"
PRODUCT_DISPLAY_NAME="JR-Bar"
MINIMUM_SUPPORTED_MACOS="26.0"
APPLE_EVENTS_USAGE_DESCRIPTION="JR-Bar uses Automation only to open a reviewed resume command in Terminal or iTerm2 when you choose Open."
FOCUS_STATUS_USAGE_DESCRIPTION="JR-Bar uses Focus Status only when you choose Allow Focus Status, so Do Not Disturb can follow whether a macOS Focus is active."
SPARKLE_FEED_URL="https://github.com/JonathanRReed/JR-Bar/releases/download/updates/appcast.xml"
SPARKLE_PUBLIC_KEY_FILE="$ROOT_DIR/packaging/sparkle_public_ed_key.txt"

APP_BUILD_SCRIPT="${APP_BUILD_SCRIPT:-$ROOT_DIR/app/scripts/build-app.sh}"
HOOK_BUILD_SCRIPT="${HOOK_BUILD_SCRIPT:-$ROOT_DIR/hook/build.sh}"
SECURITY_TOOL="${SECURITY_TOOL:-/usr/bin/security}"
CODESIGN_TOOL="${CODESIGN_TOOL:-/usr/bin/codesign}"
XCRUN_TOOL="${XCRUN_TOOL:-/usr/bin/xcrun}"

APP_SIGN_IDENTITY="${APP_SIGN_IDENTITY:-}"
INSTALLER_SIGN_IDENTITY="${INSTALLER_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-jrbar-notary}"
ALLOW_UNSIGNED="${ALLOW_UNSIGNED:-0}"
SPARKLE_ARCHIVE="${SPARKLE_ARCHIVE:-}"
SPARKLE_KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-}"
RELEASE_CHANNEL="${JRBAR_RELEASE_CHANNEL:-stable}"
SPARKLE_HISTORY_DIR="${JRBAR_SPARKLE_HISTORY_DIR:-}"

select_build_python() {
    local candidate resolved
    local candidates=()

    if [ -n "$REQUESTED_BUILD_PYTHON" ]; then
        candidates=("$REQUESTED_BUILD_PYTHON")
    else
        candidates=(
            /opt/homebrew/bin/python3.12
            python3.12
            "$HOME/.local/bin/python3.12"
            /opt/homebrew/bin/python3
            /usr/local/bin/python3
            python3
        )
    fi

    for candidate in "${candidates[@]}"; do
        if [[ "$candidate" = /* ]]; then
            resolved="$candidate"
        else
            resolved="$(command -v "$candidate" 2>/dev/null || true)"
        fi
        if [ -z "$resolved" ] || [ ! -x "$resolved" ]; then
            continue
        fi
        if "$resolved" -c 'import sys; raise SystemExit(sys.version_info[:2] != (3, 12))' 2>/dev/null; then
            printf '%s\n' "$resolved"
            return 0
        fi
    done
    return 1
}

# Signing identity selection. Prints the identity (or "-" for ad-hoc).
select_app_identity() {
    local listing
    if [ -n "$APP_SIGN_IDENTITY" ]; then
        printf '%s\n' "$APP_SIGN_IDENTITY"
        return 0
    fi
    if [ "$ALLOW_UNSIGNED" = "1" ]; then
        printf -- '-\n'
        return 0
    fi
    listing="$("$SECURITY_TOOL" find-identity -v -p codesigning 2>/dev/null || true)"
    if printf '%s\n' "$listing" | /usr/bin/grep -q '"Developer ID Application: '; then
        printf '%s\n' "$listing" | /usr/bin/sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | /usr/bin/head -1
        return 0
    fi
    if printf '%s\n' "$listing" | /usr/bin/grep -q '"Nautilus Local Dev"'; then
        printf 'Nautilus Local Dev\n'
        return 0
    fi
    printf -- '-\n'
}

select_installer_identity() {
    local listing
    if [ -n "$INSTALLER_SIGN_IDENTITY" ]; then
        printf '%s\n' "$INSTALLER_SIGN_IDENTITY"
        return 0
    fi
    if [ "$ALLOW_UNSIGNED" = "1" ]; then
        return 0
    fi
    listing="$("$SECURITY_TOOL" find-identity -v 2>/dev/null || true)"
    printf '%s\n' "$listing" | /usr/bin/sed -n 's/.*"\(Developer ID Installer: [^"]*\)".*/\1/p' | /usr/bin/head -1
}

if [ ! -f "$CONSTRAINTS" ]; then
    echo "Missing reviewed release constraints: $CONSTRAINTS" >&2
    exit 2
fi
if [ ! -f "$LOCKFILE" ]; then
    echo "Missing hash-bound release lock: $LOCKFILE" >&2
    exit 2
fi

BUILD_PYTHON="$(select_build_python || true)"
if [ -z "$BUILD_PYTHON" ]; then
    echo "JR-Bar release packaging requires Python 3.12." >&2
    echo "Install Homebrew Python 3.12 (or uv python install 3.12) or set BUILD_PYTHON to that interpreter." >&2
    exit 2
fi
if ! VERSION="$("$BUILD_PYTHON" "$ROOT_DIR/scripts/validate_release_version.py")"; then
    echo "Could not validate the JR-Bar release version." >&2
    exit 2
fi
contract() {
    "$BUILD_PYTHON" "$ROOT_DIR/scripts/release_artifact_contract.py" \
        --version "$VERSION" \
        --architecture "$ARCH" \
        --dist-dir "$DIST_DIR" \
        --format "$1"
}
OUTPUT_PKG="$(contract path)"
OUTPUT_ZIP="$(contract updater-path)"
OUTPUT_APPCAST="$(contract appcast-path)"
OUTPUT_CHANNEL_METADATA="$(contract channel-metadata-path)"

if [ ! -f "$SPARKLE_PUBLIC_KEY_FILE" ]; then
    echo "Missing reviewed Sparkle public key: $SPARKLE_PUBLIC_KEY_FILE" >&2
    exit 2
fi
if ! SPARKLE_PUBLIC_ED_KEY="$("$BUILD_PYTHON" -c '
import base64
import binascii
import pathlib
import sys

key = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").strip()
try:
    decoded = base64.b64decode(key, validate=True)
except (binascii.Error, ValueError):
    raise SystemExit(1)
if len(decoded) != 32:
    raise SystemExit(1)
print(key)
' "$SPARKLE_PUBLIC_KEY_FILE")"; then
    echo "Sparkle public key must be one base64-encoded Ed25519 public key." >&2
    exit 2
fi

case "$BUILD_DIR" in
    ""|"/")
        echo "Refusing unsafe BUILD_ROOT: $BUILD_DIR" >&2
        exit 2
        ;;
esac
case "$DIST_DIR" in
    ""|"/")
        echo "Refusing unsafe OUTPUT_ROOT: $DIST_DIR" >&2
        exit 2
        ;;
esac
case "$BUILD_PYTHON" in
    /*) ;;
    *)
        echo "BUILD_PYTHON must resolve to an absolute path: $BUILD_PYTHON" >&2
        exit 2
        ;;
esac
if [ ! -x "$BUILD_PYTHON" ]; then
    echo "BUILD_PYTHON is missing or not executable: $BUILD_PYTHON" >&2
    exit 2
fi
"$BUILD_PYTHON" -c 'import sys; raise SystemExit(sys.version_info[:2] != (3, 12))' || {
    echo "JR-Bar release packaging requires Python 3.12; got $($BUILD_PYTHON -V 2>&1)." >&2
    exit 2
}

SIGN_IDENTITY="$(select_app_identity)"
INSTALLER_IDENTITY="$(select_installer_identity)"
SIGN_KIND="ad-hoc"
HARDENED=1
case "$SIGN_IDENTITY" in
    "-") SIGN_KIND="ad-hoc" ;;
    "Developer ID Application: "*) SIGN_KIND="developer-id" ;;
    *) SIGN_KIND="local"; HARDENED=0 ;;
esac
NOTARIZE=0
if [ "$SIGN_KIND" = "developer-id" ] && [ "$ALLOW_UNSIGNED" != "1" ] && \
    "$XCRUN_TOOL" notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    NOTARIZE=1
fi
COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
if [ -n "$(git -C "$ROOT_DIR" status --porcelain 2>/dev/null || true)" ]; then
    COMMIT="$COMMIT-dirty"
fi

echo "Building JR-Bar $VERSION for $ARCH with $($BUILD_PYTHON -V 2>&1) (commit $COMMIT)"
echo "signing: $SIGN_KIND ($SIGN_IDENTITY)"
if [ "$SIGN_KIND" = "ad-hoc" ]; then
    echo "WARNING: ad-hoc signature. macOS treats an ad-hoc bundle as a DIFFERENT" >&2
    echo "         app: Notification and Automation grants will be lost and" >&2
    echo "         Gatekeeper will reject it on another Mac. Local testing only." >&2
elif [ "$SIGN_KIND" = "local" ]; then
    echo "note: local identity without a Team ID; hardened runtime is off so the app can load its own frameworks"
fi
if [ -n "$INSTALLER_IDENTITY" ]; then
    echo "installer signing: $INSTALLER_IDENTITY"
else
    echo "installer signing: none (no Developer ID Installer identity in the keychain)"
fi
if [ "$NOTARIZE" = "1" ]; then
    echo "notarization: keychain profile $NOTARY_PROFILE"
else
    echo "notarization: not notarized (no '$NOTARY_PROFILE' keychain profile, or not Developer ID signed)"
fi

/bin/rm -rf "$BUILD_DIR"
/bin/mkdir -p "$BUILD_DIR" "$DIST_DIR"
/bin/mkdir -m 700 "$RAW_EVIDENCE_DIR"
export PIP_CACHE_DIR="$BUILD_DIR/pip-cache"
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_CONSTRAINT="$CONSTRAINTS"
export PIP_BUILD_CONSTRAINT="$CONSTRAINTS"
export PYTHONHASHSEED=0
export PYINSTALLER_CONFIG_DIR="$BUILD_DIR/pyinstaller-cache"
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$ROOT_DIR" show -s --format=%ct HEAD 2>/dev/null || /bin/date +%s)}"
"$BUILD_PYTHON" -m venv "$VENV_DIR"
# --no-cache-dir is LOAD-BEARING: pip caches the built jrbar wheel
# BY VERSION, so every rebuild between version bumps could silently ship
# a stale wheel from an older commit (it did: a deploy passed md5 parity
# against its own stale build while the source had moved two commits).
"$VENV_DIR/bin/python" -m pip install \
    --no-cache-dir \
    --require-hashes \
    --only-binary=:all: \
    --requirement "$LOCKFILE"
# pip 26 refuses a build constraint together with --no-build-isolation. The
# reviewed runtime constraint still applies through PIP_CONSTRAINT, and every
# build requirement is already installed from the hash-bound binary lock.
env -u PIP_BUILD_CONSTRAINT "$VENV_DIR/bin/python" -m pip install "$ROOT_DIR" --no-deps --no-build-isolation
"$VENV_DIR/bin/python" -m pip check
LC_ALL=C "$VENV_DIR/bin/python" -m pip list --format=freeze \
    | /usr/bin/sort > "$ENVIRONMENT_SNAPSHOT"

echo "==> Swift app"
/bin/mkdir -p "$(/usr/bin/dirname "$SWIFT_APP")"
JRBAR_BUNDLE="$SWIFT_APP" JRBAR_VERSION="$VERSION" JRBAR_SKIP_SIGN=1 "$APP_BUILD_SCRIPT"
if [ ! -x "$SWIFT_APP/Contents/MacOS/JR-Bar" ]; then
    echo "the app build did not produce $SWIFT_APP/Contents/MacOS/JR-Bar" >&2
    exit 1
fi

echo "==> hook shim"
JRBAR_HOOK_BUILD_DIR="$HOOK_DIR" "$HOOK_BUILD_SCRIPT"
if [ ! -x "$HOOK_DIR/jrbar-hook" ]; then
    echo "the shim build did not produce $HOOK_DIR/jrbar-hook" >&2
    exit 1
fi

echo "==> daemon (PyInstaller $PINNED_PYINSTALLER, onedir app bundle)"
"$VENV_DIR/bin/pyinstaller" \
    --noconfirm --clean --onedir --windowed \
    --name jrbar-core \
    --osx-bundle-identifier "$CORE_ID" \
    --distpath "$BUILD_DIR/pyinstaller" \
    --workpath "$BUILD_DIR/work" \
    --specpath "$BUILD_DIR" \
    --collect-submodules jrbar \
    --collect-submodules Cocoa \
    --collect-data jrbar.resources \
    --copy-metadata jrbar \
    --hidden-import jrbar.creator_micro_adapter \
    --hidden-import jrbar.creator_micro_hidapi \
    --hidden-import hid \
    "$ROOT_DIR/packaging/jrbar_entry.py"
if [ ! -x "$CORE_APP/Contents/MacOS/jrbar-core" ]; then
    echo "PyInstaller did not produce $CORE_APP/Contents/MacOS/jrbar-core" >&2
    exit 1
fi

echo "==> assembling $APP_PATH"
/bin/mkdir -p "$(/usr/bin/dirname "$APP_PATH")"
/usr/bin/ditto "$SWIFT_APP" "$APP_PATH"
/bin/mkdir -p "$HELPERS"
/usr/bin/ditto "$CORE_APP" "$HELPERS/jrbar-core.app"
/usr/bin/install -m 755 "$HOOK_DIR/jrbar-hook" "$HELPERS/jrbar-hook"
# The daemon is headless: never a Dock tile, never a window. It inherits the
# app's Automation grant through the process tree, but TCC reads the usage
# strings from the bundle it finds first, so it carries them too.
CORE_PLIST="$HELPERS/jrbar-core.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$CORE_PLIST" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :LSUIElement true" "$CORE_PLIST"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string $MINIMUM_SUPPORTED_MACOS" "$CORE_PLIST" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $MINIMUM_SUPPORTED_MACOS" "$CORE_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$CORE_PLIST" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CORE_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VERSION" "$CORE_PLIST" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$CORE_PLIST"
/usr/libexec/PlistBuddy -c "Add :NSAppleEventsUsageDescription string $APPLE_EVENTS_USAGE_DESCRIPTION" "$CORE_PLIST" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :NSAppleEventsUsageDescription $APPLE_EVENTS_USAGE_DESCRIPTION" "$CORE_PLIST"

if [ -n "$SPARKLE_ARCHIVE" ]; then
    "$VENV_DIR/bin/python" "$ROOT_DIR/scripts/prepare_sparkle.py" --output "$SPARKLE_DISTRIBUTION" \
        --archive "$SPARKLE_ARCHIVE"
else
    "$VENV_DIR/bin/python" "$ROOT_DIR/scripts/prepare_sparkle.py" --output "$SPARKLE_DISTRIBUTION"
fi
if [ -e "$APP_PATH/Contents/Frameworks/Sparkle.framework" ] || \
    [ -L "$APP_PATH/Contents/Frameworks/Sparkle.framework" ]; then
    echo "Refusing to overwrite an unexpected embedded Sparkle.framework." >&2
    exit 2
fi
/bin/mkdir -p \
    "$APP_PATH/Contents/Frameworks" \
    "$APP_PATH/Contents/Resources/ThirdPartyLicenses"
# ditto preserves the framework's reviewed relative symlinks and executable bits.
/usr/bin/ditto \
    "$SPARKLE_DISTRIBUTION/Sparkle.framework" \
    "$APP_PATH/Contents/Frameworks/Sparkle.framework"
/usr/bin/ditto \
    "$SPARKLE_DISTRIBUTION/LICENSE" \
    "$APP_PATH/Contents/Resources/ThirdPartyLicenses/Sparkle.txt"

/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$APP_PATH/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VERSION" "$APP_PATH/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $PRODUCT_DISPLAY_NAME" "$APP_PATH/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $PRODUCT_DISPLAY_NAME" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleName string $PRODUCT_DISPLAY_NAME" "$APP_PATH/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $PRODUCT_DISPLAY_NAME" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string $MINIMUM_SUPPORTED_MACOS" "$APP_PATH/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $MINIMUM_SUPPORTED_MACOS" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSAppleEventsUsageDescription string $APPLE_EVENTS_USAGE_DESCRIPTION" "$APP_PATH/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :NSAppleEventsUsageDescription $APPLE_EVENTS_USAGE_DESCRIPTION" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSFocusStatusUsageDescription string $FOCUS_STATUS_USAGE_DESCRIPTION" "$APP_PATH/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :NSFocusStatusUsageDescription $FOCUS_STATUS_USAGE_DESCRIPTION" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SUFeedURL string $SPARKLE_FEED_URL" "$APP_PATH/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :SUFeedURL $SPARKLE_FEED_URL" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_ED_KEY" "$APP_PATH/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $SPARKLE_PUBLIC_ED_KEY" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SURequireSignedFeed bool true" "$APP_PATH/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :SURequireSignedFeed true" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SUVerifyUpdateBeforeExtraction bool true" "$APP_PATH/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :SUVerifyUpdateBeforeExtraction true" "$APP_PATH/Contents/Info.plist"
# The app hands this to the daemon as JRBAR_COMMIT (the doctor reply's commit).
/usr/libexec/PlistBuddy -c "Add :JRBarCommit string $COMMIT" "$APP_PATH/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :JRBarCommit $COMMIT" "$APP_PATH/Contents/Info.plist"

# Downloads and copied workspace resources can carry Finder or provenance
# metadata that codesign rejects. Limit cleanup to the isolated candidate.
/usr/bin/xattr -cr "$APP_PATH"

sign_args=("$APP_PATH" --identity "$SIGN_IDENTITY" --entitlements "$ROOT_DIR/packaging/entitlements.plist")
if [ "$HARDENED" != "1" ]; then
    sign_args+=(--no-runtime)
fi
if [ "$SIGN_KIND" != "developer-id" ]; then
    sign_args+=(--no-timestamp)
fi
"$VENV_DIR/bin/python" "$ROOT_DIR/packaging/sign_macos_app.py" "${sign_args[@]}"

SIGNED_TEAM=""
if [ "$SIGN_KIND" = "developer-id" ]; then
    SIGNED_TEAM="$("$CODESIGN_TOOL" -dv --verbose=4 "$APP_PATH" 2>&1 \
        | /usr/bin/awk -F= '/^TeamIdentifier=/ {print $2}')"
    if [ -z "$SIGNED_TEAM" ] || [ "$SIGNED_TEAM" = "not set" ]; then
        echo "FATAL: asked for '$SIGN_IDENTITY' but the bundle carries no" >&2
        echo "       TeamIdentifier -- it is ad-hoc signed. Refusing to ship a" >&2
        echo "       bundle that would silently lose the user's TCC grants." >&2
        exit 1
    fi
    echo "signed by team $SIGNED_TEAM"
fi

"$VENV_DIR/bin/python" "$ROOT_DIR/packaging/verify_macos_app.py" "$APP_PATH"
"$VENV_DIR/bin/python" "$ROOT_DIR/packaging/verify_entitlements.py" "$APP_PATH"
sparkle_verify_args=("$APP_PATH")
if [ "$SIGN_KIND" = "developer-id" ]; then
    sparkle_verify_args+=(--production --expected-team "$SIGNED_TEAM")
fi
"$VENV_DIR/bin/python" "$ROOT_DIR/packaging/verify_sparkle_bundle.py" \
    "${sparkle_verify_args[@]}"

export COPYFILE_DISABLE=1

if [ "$NOTARIZE" = "1" ]; then
    echo "==> notarizing the app"
    /usr/bin/ditto -c -k --keepParent "$APP_PATH" "$APP_NOTARY_ZIP"
    app_notary_response="$RAW_EVIDENCE_DIR/app-notary-submission.json"
    app_notary_log="$RAW_EVIDENCE_DIR/app-notary-log.json"
    app_submitted_sha="$RAW_EVIDENCE_DIR/app-notary-submitted-zip.sha256"
    /usr/bin/shasum -a 256 "$APP_NOTARY_ZIP" \
        | /usr/bin/awk '{print $1}' > "$app_submitted_sha"
    "$XCRUN_TOOL" notarytool submit "$APP_NOTARY_ZIP" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait \
        --output-format json > "$app_notary_response"
    app_submission_id="$("$BUILD_PYTHON" "$ROOT_DIR/scripts/release_evidence.py" \
        notary-submission-id \
        --response "$app_notary_response")"
    "$XCRUN_TOOL" notarytool log "$app_submission_id" \
        --keychain-profile "$NOTARY_PROFILE" \
        "$app_notary_log"
    /bin/chmod 600 "$app_notary_response" "$app_notary_log" "$app_submitted_sha"
    "$XCRUN_TOOL" stapler staple "$APP_PATH"
    "$XCRUN_TOOL" stapler validate "$APP_PATH"

    "$VENV_DIR/bin/python" "$ROOT_DIR/packaging/verify_macos_app.py" "$APP_PATH"
    "$VENV_DIR/bin/python" "$ROOT_DIR/packaging/verify_sparkle_bundle.py" \
        "$APP_PATH" \
        --production \
        --expected-team "$SIGNED_TEAM"
fi

echo "==> Sparkle archive $OUTPUT_ZIP"
/bin/rm -f "$OUTPUT_ZIP"
"$VENV_DIR/bin/python" "$ROOT_DIR/scripts/package_sparkle_archive.py" \
    --app "$APP_PATH" \
    --output "$OUTPUT_ZIP"

echo "==> package $OUTPUT_PKG"
package_args=(
    --app "$APP_PATH"
    --scripts "$ROOT_DIR/packaging/scripts"
    --component-pkg "$COMPONENT_PKG"
    --output-pkg "$OUTPUT_PKG"
    --identifier "$APP_ID"
    --version "$VERSION"
)
if [ -n "$INSTALLER_IDENTITY" ]; then
    package_args+=(--installer-sign-identity "$INSTALLER_IDENTITY")
fi
"$VENV_DIR/bin/python" "$ROOT_DIR/scripts/package_macos_artifact.py" \
    "${package_args[@]}"

if [ "$NOTARIZE" = "1" ] && [ -n "$INSTALLER_IDENTITY" ]; then
    echo "==> notarizing the package"
    notary_response="$RAW_EVIDENCE_DIR/notary-submission.json"
    notary_log="$RAW_EVIDENCE_DIR/notary-log.json"
    submitted_sha="$RAW_EVIDENCE_DIR/notary-submitted-pkg.sha256"
    /usr/bin/shasum -a 256 "$OUTPUT_PKG" \
        | /usr/bin/awk '{print $1}' > "$submitted_sha"
    "$XCRUN_TOOL" notarytool submit "$OUTPUT_PKG" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait \
        --output-format json > "$notary_response"
    submission_id="$("$BUILD_PYTHON" "$ROOT_DIR/scripts/release_evidence.py" \
        notary-submission-id \
        --response "$notary_response")"
    "$XCRUN_TOOL" notarytool log "$submission_id" \
        --keychain-profile "$NOTARY_PROFILE" \
        "$notary_log"
    /bin/chmod 600 "$notary_response" "$notary_log" "$submitted_sha"
    "$XCRUN_TOOL" stapler staple "$OUTPUT_PKG"
    "$XCRUN_TOOL" stapler validate "$OUTPUT_PKG"
elif [ "$NOTARIZE" = "1" ]; then
    echo "package not notarized: an unsigned PKG cannot be notarized (no Developer ID Installer identity)"
fi

# The signed appcast needs the private half of packaging/sparkle_public_ed_key.txt
# in the login keychain. Try the named account, then Sparkle's default one.
echo "==> appcast"
APPCAST_ACCOUNT=""
if [ "$ALLOW_UNSIGNED" != "1" ] && [ -x "$SPARKLE_DISTRIBUTION/bin/generate_keys" ]; then
    for account in "$SPARKLE_KEY_ACCOUNT" ed25519 io.jrbar.app com.jonathanreed.jrbar; do
        [ -n "$account" ] || continue
        if [ "$("$SPARKLE_DISTRIBUTION/bin/generate_keys" --account "$account" -p 2>/dev/null || true)" = "$SPARKLE_PUBLIC_ED_KEY" ]; then
            APPCAST_ACCOUNT="$account"
            break
        fi
    done
fi
if [ -n "$APPCAST_ACCOUNT" ]; then
    candidate_id="$(/usr/bin/shasum -a 256 "$OUTPUT_ZIP" | /usr/bin/awk '{print $1}')"
    channel_args=(
        --sparkle-distribution "$SPARKLE_DISTRIBUTION"
        --archive "$OUTPUT_ZIP"
        --output-dir "$DIST_DIR"
        --candidate-id "$candidate_id"
        --channel "$RELEASE_CHANNEL"
        --keychain-account "$APPCAST_ACCOUNT"
    )
    if [ -n "$SPARKLE_HISTORY_DIR" ]; then
        channel_args+=(--previous-appcast "$SPARKLE_HISTORY_DIR/appcast.xml")
        for previous in "$SPARKLE_HISTORY_DIR"/JR-Bar-*.zip; do
            [ -f "$previous" ] || continue
            [ "$(/usr/bin/basename "$previous")" != "$(/usr/bin/basename "$OUTPUT_ZIP")" ] || continue
            channel_args+=(--previous-archive "$previous")
        done
    fi
    "$VENV_DIR/bin/python" "$ROOT_DIR/scripts/generate_sparkle_channel.py" "${channel_args[@]}"
    echo "signed appcast: $OUTPUT_APPCAST (keychain account $APPCAST_ACCOUNT, channel $RELEASE_CHANNEL)"
else
    /bin/rm -f "$OUTPUT_APPCAST" "$OUTPUT_CHANNEL_METADATA"
    if [ "$ALLOW_UNSIGNED" = "1" ]; then
        echo "appcast not signed: ALLOW_UNSIGNED is local-only."
    else
        echo "appcast not signed: no keychain account holds the Sparkle key for $SPARKLE_PUBLIC_ED_KEY" >&2
        echo "  (tried: ${SPARKLE_KEY_ACCOUNT:-<SPARKLE_KEY_ACCOUNT unset>}, ed25519, io.jrbar.app, com.jonathanreed.jrbar)" >&2
    fi
fi

echo
echo "JR-Bar $VERSION ($COMMIT)"
echo "  app:        $APP_PATH"
for artifact in "$OUTPUT_PKG" "$OUTPUT_ZIP" "$OUTPUT_APPCAST" "$OUTPUT_CHANNEL_METADATA"; do
    if [ -f "$artifact" ]; then
        printf '  %-11s %s (%s)\n' "$(/usr/bin/basename "$artifact"):" "$artifact" "$(/usr/bin/du -h "$artifact" | /usr/bin/awk '{print $1}')"
    fi
done
echo "  signed:     $SIGN_KIND ($SIGN_IDENTITY)"
if [ -n "$INSTALLER_IDENTITY" ]; then
    echo "  installer:  signed ($INSTALLER_IDENTITY)"
else
    echo "  installer:  unsigned"
fi
if [ "$NOTARIZE" = "1" ]; then
    echo "  notarized:  yes (app stapled$( [ -n "$INSTALLER_IDENTITY" ] && echo ', PKG stapled'))"
else
    echo "  notarized:  not notarized"
fi
if [ "$ALLOW_UNSIGNED" = "1" ]; then
    echo "ALLOW_UNSIGNED is local-only. This package is not a production update candidate."
fi
