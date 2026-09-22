#!/bin/zsh
# Builds app/build/JR-Bar.app from the SwiftPM package with the Command Line
# Tools only (no xcodebuild). Signs with "Nautilus Local Dev" when that
# identity is in the keychain, otherwise ad-hoc (JRBAR_SKIP_SIGN=1 leaves the
# bundle unsigned for packaging/build_macos_pkg.sh, which signs the whole
# assembled bundle inside out).
#
# The version is the project version from ../pyproject.toml (JRBAR_VERSION
# overrides it). CFBundleVersion is the build number -- the commit count of
# this history, the same number packaging/build_macos_pkg.sh stamps
# (JRBAR_BUILD_NUMBER overrides it) -- because Sparkle orders builds by
# CFBundleVersion, and two rebuilds of one version must still sort.
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$APP_DIR/build"
# JRBAR_BUNDLE overrides the output path (run-dev.sh builds JR-Bar-dev.app so
# the development copy never replaces the one install-agents.sh copies).
BUNDLE="${JRBAR_BUNDLE:-$BUILD_DIR/JR-Bar.app}"
IDENTITY="${JRBAR_SIGN_IDENTITY:-Nautilus Local Dev}"
VERSION="${JRBAR_VERSION:-$(sed -n 's/^version = "\([^"]*\)"$/\1/p' "$APP_DIR/../pyproject.toml" | head -1)}"
[[ -n "$VERSION" ]] || { echo "cannot read the project version from pyproject.toml" >&2; exit 1; }
# A dev bundle built outside a checkout still builds; it just sorts first.
BUILD_NUMBER="${JRBAR_BUILD_NUMBER:-$(git -C "$APP_DIR/.." rev-list --count HEAD 2>/dev/null || echo 1)}"

# Sparkle: link the pinned framework when it is around. JRBAR_SPARKLE_FRAMEWORK_DIR
# names the distribution directory (the packaging script's
# build/macos-pkg/sparkle-distribution is the default once `make package` has
# run); empty disables it. JRBAR_EMBED_SPARKLE=0 leaves the framework out of
# the bundle (the packaging script embeds and signs it itself).
if [[ -z "${JRBAR_SPARKLE_FRAMEWORK_DIR+x}" ]]; then
    JRBAR_SPARKLE_FRAMEWORK_DIR="$APP_DIR/../build/macos-pkg/sparkle-distribution"
fi
if [[ -n "$JRBAR_SPARKLE_FRAMEWORK_DIR" && -f "$JRBAR_SPARKLE_FRAMEWORK_DIR/Sparkle.framework/Modules/module.modulemap" ]]; then
    JRBAR_SPARKLE_FRAMEWORK_DIR="$(cd "$JRBAR_SPARKLE_FRAMEWORK_DIR" && pwd)"
    SPARKLE_LINKED=1
else
    JRBAR_SPARKLE_FRAMEWORK_DIR=""
    SPARKLE_LINKED=0
fi
export JRBAR_SPARKLE_FRAMEWORK_DIR
SPARKLE_PUBLIC_KEY="$(tr -d '[:space:]' < "$APP_DIR/../packaging/sparkle_public_ed_key.txt")"
SPARKLE_FEED_URL="https://github.com/JonathanRReed/JR-Bar/releases/download/updates/appcast.xml"

cd "$APP_DIR"
if [[ "$SPARKLE_LINKED" == "1" ]]; then
    echo "==> swift build -c release (Sparkle from $JRBAR_SPARKLE_FRAMEWORK_DIR)"
else
    echo "==> swift build -c release (no Sparkle.framework: the updater is a stub)"
fi
# The manifest reads JRBAR_SPARKLE_FRAMEWORK_DIR to pick the link flags;
# SwiftPM caches both that evaluation and the resulting build products
# without keying on the environment — a stub-flavoured cache would
# silently ship a Sparkle-less binary. Track the mode ourselves: a flip
# wipes .build so the compile runs under this invocation's flags.
MODE_STAMP=".build/.sparkle-mode"
if [[ ! -f "$MODE_STAMP" || "$(cat "$MODE_STAMP")" != "$SPARKLE_LINKED" ]]; then
    rm -rf .build
    mkdir -p .build
    echo "$SPARKLE_LINKED" > "$MODE_STAMP"
fi
# Products build separately: a combined `--product A --product B` can
# report "Build complete" while silently skipping A — measured twice
# shipping a stale JRBarApp (2026-09-21).
swift build -c release --product JRBarApp
swift build -c release --product jrbar-asserter
BIN_DIR="$(swift build -c release --show-bin-path)"
BINARY="$BIN_DIR/JRBarApp"
[[ -x "$BINARY" ]] || { echo "binary not found at $BINARY" >&2; exit 1; }
ASSERTER="$BIN_DIR/jrbar-asserter"
[[ -x "$ASSERTER" ]] || { echo "asserter not found at $ASSERTER" >&2; exit 1; }

echo "==> assembling $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BINARY" "$BUNDLE/Contents/MacOS/JR-Bar"
# The Command Line Tools' Swift driver records its own toolchain directory as
# an rpath; every Swift library the app links lives in /usr/lib/swift on the
# macOS it targets, and the packaged bundle must not point outside itself.
for rpath in $(otool -l "$BUNDLE/Contents/MacOS/JR-Bar" | awk '/cmd LC_RPATH/{getline; getline; print $2}'); do
    case "$rpath" in
        /Library/Developer/*|/Applications/Xcode*) install_name_tool -delete_rpath "$rpath" "$BUNDLE/Contents/MacOS/JR-Bar" ;;
    esac
done
cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>JR-Bar</string>
	<key>CFBundleExecutable</key>
	<string>JR-Bar</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>com.jonathanreed.jrbar</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>JR-Bar</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUILD_NUMBER</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.developer-tools</string>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSBluetoothAlwaysUsageDescription</key>
	<string>JR-Bar announces a device connecting in the notch — "AirPods connected". Nothing is paired or sent.</string>
	<key>NSCameraUsageDescription</key>
	<string>JR-Bar's Mirror row shows the Mac's own camera in the notch card — and only while the row is on. Nothing is recorded or sent.</string>
	<key>NSCalendarsFullAccessUsageDescription</key>
	<string>JR-Bar shows the next event on the shelf and the Dock's Calendar tile, and only after you ask it to. Nothing leaves the Mac.</string>
	<key>NSRemindersFullAccessUsageDescription</key>
	<string>JR-Bar lists your next reminders on the shelf — and only after you ask it to. Checking one off writes back to Reminders; nothing else is sent anywhere.</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>Copyright © 2026 Jonathan Reed</string>
	<key>NSSupportsAutomaticGraphicsSwitching</key>
	<true/>
	<key>SUFeedURL</key>
	<string>$SPARKLE_FEED_URL</string>
	<key>SUPublicEDKey</key>
	<string>$SPARKLE_PUBLIC_KEY</string>
	<key>SURequireSignedFeed</key>
	<true/>
	<key>SUVerifyUpdateBeforeExtraction</key>
	<true/>
</dict>
</plist>
PLIST
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"
if [[ "$SPARKLE_LINKED" == "1" && "${JRBAR_EMBED_SPARKLE:-1}" != "0" ]]; then
    echo "==> embedding Sparkle.framework"
    mkdir -p "$BUNDLE/Contents/Frameworks"
    ditto "$JRBAR_SPARKLE_FRAMEWORK_DIR/Sparkle.framework" "$BUNDLE/Contents/Frameworks/Sparkle.framework"
fi

echo "==> rendering AppIcon.icns"
# Every size is drawn at its own pixel size by the script (no sips
# downsampling); JRBAR_ICONSET_KEEP=/dir also keeps the PNGs for review.
ICON_TMP="$(mktemp -d)"
ICONSET="$ICON_TMP/AppIcon.iconset"
swift "$APP_DIR/scripts/make-icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$BUNDLE/Contents/Resources/AppIcon.icns"
if [[ -n "${JRBAR_ICONSET_KEEP:-}" ]]; then
    mkdir -p "$JRBAR_ICONSET_KEEP"
    cp "$ICONSET"/*.png "$JRBAR_ICONSET_KEEP/"
fi
rm -rf "$ICON_TMP"

# Contents/Helpers: the PyInstaller daemon + the hook shim, the same
# pair packaging/build_macos_pkg.sh lays down. A bundle without them
# leaves the app hunting a socket nothing listens on — "Monitor not
# connected", every daemon-fed surface stale. Present only after
# `make package` (or the pkg script) has built them; absent, the app
# still builds and falls back to whatever core is running.
CORE_APP="$APP_DIR/../build/macos-pkg/pyinstaller/jrbar-core.app"
HOOK_BIN="$APP_DIR/../build/macos-pkg/hook/jrbar-hook"
HELPERS="$BUNDLE/Contents/Helpers"
# The assertion holder needs its own bundle id — a bare binary inside
# our bundle resolves Bundle.main to com.jonathanreed.jrbar and the
# agent hides our own icon as the holder's (measured 2026-09-21).
ASSERTER_APP="$HELPERS/jrbar-asserter.app"
mkdir -p "$ASSERTER_APP/Contents/MacOS"
install -m 755 "$ASSERTER" "$ASSERTER_APP/Contents/MacOS/jrbar-asserter"
# Same rule as the app binary: no toolchain rpaths may survive into a
# bundle — this used to happen only in the packaging script, which left
# dev bundles carrying Command Line Tools paths.
for rpath in $(otool -l "$ASSERTER_APP/Contents/MacOS/jrbar-asserter" | awk '/cmd LC_RPATH/{getline; getline; print $2}'); do
    case "$rpath" in
        /Library/Developer/*|/Applications/Xcode*) install_name_tool -delete_rpath "$rpath" "$ASSERTER_APP/Contents/MacOS/jrbar-asserter" ;;
    esac
done
cat > "$ASSERTER_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>jrbar-asserter</string>
	<key>CFBundleIdentifier</key>
	<string>com.jonathanreed.jrbar.asserter</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>jrbar-asserter</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
PLIST
if [[ -x "$CORE_APP/Contents/MacOS/jrbar-core" ]]; then
    echo "==> bundling Contents/Helpers (jrbar-core.app + jrbar-hook)"
    mkdir -p "$HELPERS"
    ditto "$CORE_APP" "$HELPERS/jrbar-core.app"
    CORE_PLIST="$HELPERS/jrbar-core.app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$CORE_PLIST" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c "Set :LSUIElement true" "$CORE_PLIST"
    /usr/libexec/PlistBuddy -c "Add :LSAppNapIsDisabled bool true" "$CORE_PLIST" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c "Set :LSAppNapIsDisabled true" "$CORE_PLIST"
    if [[ -x "$HOOK_BIN" ]]; then
        install -m 755 "$HOOK_BIN" "$HELPERS/jrbar-hook"
    fi
else
    echo "==> no PyInstaller daemon at $CORE_APP — bundle will rely on an external core"
fi

if [[ "${JRBAR_SKIP_SIGN:-0}" == "1" ]]; then
    echo "built $BUNDLE (unsigned: JRBAR_SKIP_SIGN=1)"
    exit 0
fi
echo "==> codesign"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    SIGN_IDENTITY="$IDENTITY"
    echo "signing with identity: $IDENTITY"
else
    SIGN_IDENTITY="-"
    echo "signing ad-hoc (identity \"$IDENTITY\" unavailable or failed)"
fi
# Nested code first, the enclosing bundle last — the same inside-out
# order the packaging script signs in.
if [[ -d "$HELPERS" ]]; then
    find "$HELPERS" -type f \( -name "*.dylib" -o -perm +111 \) -print0 \
        | while IFS= read -r -d '' f; do
            codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$f" 2>/dev/null || true
        done
    find "$HELPERS" -maxdepth 1 -name "*.app" -print0 \
        | while IFS= read -r -d '' helper; do
            codesign --force --deep --sign "$SIGN_IDENTITY" --timestamp=none "$helper" 2>/dev/null || true
        done
fi
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$BUNDLE"
codesign --verify --deep --strict "$BUNDLE" && echo "codesign verify: ok"
echo "built $BUNDLE"
