#!/bin/bash
set -euo pipefail

# Build Vibe Usage.app from SPM release binary
# Usage: ./scripts/build-app.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="Vibe Usage"
BUNDLE_ID="ai.vibecafe.vibe-usage"
EXECUTABLE="VibeUsage"
BUILD_DIR="$PROJECT_DIR/.build/release"
DIST_DIR="$PROJECT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
ICON_SOURCE_DIR="$PROJECT_DIR/VibeUsage/Resources/Assets.xcassets/AppIcon.appiconset"

echo "==> Building release binary..."
cd "$PROJECT_DIR"
swift build -c release

echo "==> Creating .app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BUILD_DIR/$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/"

# Copy Info.plist
cp "$PROJECT_DIR/VibeUsage/Info.plist" "$APP_BUNDLE/Contents/"

# Copy SPM resource bundle (contains menubar-icon.png and other processed resources)
RESOURCE_BUNDLE="$BUILD_DIR/VibeUsage_VibeUsage.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
    cp -R "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
    echo "    Copied SPM resource bundle"
else
    echo "    WARNING: SPM resource bundle not found at $RESOURCE_BUNDLE"
fi

# Generate .icns from PNGs
echo "==> Generating AppIcon.icns..."
ICONSET_DIR=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET_DIR"

cp "$ICON_SOURCE_DIR/icon_16x16.png"      "$ICONSET_DIR/icon_16x16.png"
cp "$ICON_SOURCE_DIR/icon_16x16@2x.png"   "$ICONSET_DIR/icon_16x16@2x.png"
cp "$ICON_SOURCE_DIR/icon_32x32.png"       "$ICONSET_DIR/icon_32x32.png"
cp "$ICON_SOURCE_DIR/icon_32x32@2x.png"   "$ICONSET_DIR/icon_32x32@2x.png"
cp "$ICON_SOURCE_DIR/icon_128x128.png"     "$ICONSET_DIR/icon_128x128.png"
cp "$ICON_SOURCE_DIR/icon_128x128@2x.png"  "$ICONSET_DIR/icon_128x128@2x.png"
cp "$ICON_SOURCE_DIR/icon_256x256.png"     "$ICONSET_DIR/icon_256x256.png"
cp "$ICON_SOURCE_DIR/icon_256x256@2x.png"  "$ICONSET_DIR/icon_256x256@2x.png"
cp "$ICON_SOURCE_DIR/icon_512x512.png"     "$ICONSET_DIR/icon_512x512.png"
cp "$ICON_SOURCE_DIR/icon_512x512@2x.png"  "$ICONSET_DIR/icon_512x512@2x.png"

iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET_DIR")"
echo "    Generated AppIcon.icns"

# Ad-hoc codesign
echo "==> Codesigning (ad-hoc)..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo ""
echo "==> Done! App bundle at:"
echo "    $APP_BUNDLE"
echo ""
echo "    To install: cp -R \"$APP_BUNDLE\" /Applications/"
echo "    To run:     open \"$APP_BUNDLE\""
