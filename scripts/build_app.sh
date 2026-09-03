#!/bin/bash
# Builds MiraEQ.app and a distributable dmg.
# Usage: scripts/build_app.sh [version]
set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    # Prefer the latest git tag (vX.Y.Z) so the DMG version never drifts
    # behind releases; fall back to a dev version for untagged checkouts.
    if VERSION_FROM_GIT="$(git describe --tags --abbrev=0 2>/dev/null)"; then
        VERSION="${VERSION_FROM_GIT#v}"
    else
        VERSION="0.0.0-dev"
    fi
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/.build/release"
OUT_DIR="$ROOT/dist"
APP="$OUT_DIR/MiraEQ.app"
DMG="$OUT_DIR/MiraEQ-$VERSION.dmg"

cd "$ROOT"
swift build -c release

rm -rf "$OUT_DIR"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/presets/device"

cp "$BUILD_DIR/MiraEQ" "$APP/Contents/MacOS/MiraEQ"
cp "$ROOT"/presets/device/*.txt "$APP/Contents/Resources/presets/device/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>MiraEQ</string>
    <key>CFBundleIdentifier</key>
    <string>com.noxlume03.miraeq</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>MiraEQ</string>
    <key>CFBundleDisplayName</key>
    <string>MiraEQ</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.2</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAudioCaptureUsageDescription</key>
    <string>MiraEQ captures system audio so it can apply the selected EQ preset before playback.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>MiraEQ needs audio access only to process system playback with the selected EQ preset.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"

STAGING="$OUT_DIR/dmg-staging"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
# Keep Finder metadata out of the distributable.
find "$STAGING" -name '.DS_Store' -delete || true
hdiutil create -volname "MiraEQ" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

echo "Built: $APP"
echo "DMG:   $DMG"
shasum -a 256 "$DMG"
