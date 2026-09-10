#!/bin/zsh
# Builds app/build/JR-Bar.app from the SwiftPM package with the Command Line
# Tools only (no xcodebuild). Signs with "Nautilus Local Dev" when that
# identity is in the keychain, otherwise ad-hoc (JRBAR_SKIP_SIGN=1 leaves the
# bundle unsigned for packaging/build_macos_pkg.sh, which signs the whole
# assembled bundle inside out).
#
# The version is the project version from ../pyproject.toml (JRBAR_VERSION
# overrides it); CFBundleVersion is the same string so Sparkle compares
# releases by it.
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$APP_DIR/build"
# JRBAR_BUNDLE overrides the output path (run-dev.sh builds JR-Bar-dev.app so
# the development copy never replaces the one install-agents.sh copies).
BUNDLE="${JRBAR_BUNDLE:-$BUILD_DIR/JR-Bar.app}"
IDENTITY="${JRBAR_SIGN_IDENTITY:-Nautilus Local Dev}"
VERSION="${JRBAR_VERSION:-$(sed -n 's/^version = "\([^"]*\)"$/\1/p' "$APP_DIR/../pyproject.toml" | head -1)}"
[[ -n "$VERSION" ]] || { echo "cannot read the project version from pyproject.toml" >&2; exit 1; }

cd "$APP_DIR"
echo "==> swift build -c release"
swift build -c release --product JRBarApp
BIN_DIR="$(swift build -c release --show-bin-path)"
BINARY="$BIN_DIR/JRBarApp"
[[ -x "$BINARY" ]] || { echo "binary not found at $BINARY" >&2; exit 1; }

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
	<string>$VERSION</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.developer-tools</string>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>Copyright © 2026 Jonathan Reed</string>
	<key>NSSupportsAutomaticGraphicsSwitching</key>
	<true/>
</dict>
</plist>
PLIST
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

echo "==> rendering AppIcon.icns"
ICON_TMP="$(mktemp -d)"
swift "$APP_DIR/scripts/make-icon.swift" "$ICON_TMP/icon_1024.png"
ICONSET="$ICON_TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_TMP/icon_1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$ICON_TMP/icon_1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$BUNDLE/Contents/Resources/AppIcon.icns"
rm -rf "$ICON_TMP"

if [[ "${JRBAR_SKIP_SIGN:-0}" == "1" ]]; then
    echo "built $BUNDLE (unsigned: JRBAR_SKIP_SIGN=1)"
    exit 0
fi
echo "==> codesign"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\"" \
    && codesign --force --sign "$IDENTITY" --timestamp=none "$BUNDLE" 2>/dev/null; then
    echo "signed with identity: $IDENTITY"
else
    codesign --force --sign - "$BUNDLE"
    echo "signed ad-hoc (identity \"$IDENTITY\" unavailable or failed)"
fi
codesign --verify --deep --strict "$BUNDLE" && echo "codesign verify: ok"
echo "built $BUNDLE"
