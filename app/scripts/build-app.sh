#!/bin/zsh
# Builds app/build/JR-Bar.app from the SwiftPM package with the Command Line
# Tools only (no xcodebuild). Signs with "Nautilus Local Dev" when that
# identity is in the keychain, otherwise ad-hoc.
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$APP_DIR/build"
# JRBAR_BUNDLE overrides the output path (run-dev.sh builds JR-Bar-dev.app so
# the development copy never replaces the one install-agents.sh copies).
BUNDLE="${JRBAR_BUNDLE:-$BUILD_DIR/JR-Bar.app}"
IDENTITY="${JRBAR_SIGN_IDENTITY:-Nautilus Local Dev}"

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
cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
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
	<string>0.1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
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
