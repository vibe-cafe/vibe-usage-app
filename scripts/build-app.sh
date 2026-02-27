#!/bin/bash
set -euo pipefail

# Build Vibe Usage.app from SPM release binary
# Usage: ./scripts/build-app.sh [--notarize]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="Vibe Usage"
BUNDLE_ID="ai.vibecafe.vibe-usage"
EXECUTABLE="VibeUsage"
BUILD_DIR="$PROJECT_DIR/.build/release"
DIST_DIR="$PROJECT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
ZIP_PATH="$DIST_DIR/$APP_NAME.zip"
ICON_SOURCE_DIR="$PROJECT_DIR/VibeUsage/Resources/Assets.xcassets/AppIcon.appiconset"
SIGN_IDENTITY="Developer ID Application: Yin Ming (D33463FWDZ)"
NOTARIZE_PROFILE="VibeUsage"

NOTARIZE=false
if [[ "${1:-}" == "--notarize" ]]; then
    NOTARIZE=true
fi

echo "==> Building release binary..."
cd "$PROJECT_DIR"
swift build -c release

echo "==> Creating .app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Embed Sparkle.framework
echo "==> Embedding Sparkle.framework..."
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
SPARKLE_FRAMEWORK=$(find "$PROJECT_DIR/.build/artifacts" -name "Sparkle.framework" -path "*/macos-*" | head -1)
if [ -z "$SPARKLE_FRAMEWORK" ]; then
    # Fallback: search in the build directory
    SPARKLE_FRAMEWORK=$(find "$PROJECT_DIR/.build" -name "Sparkle.framework" -not -path "*/Sparkle.framework/Versions/*" | head -1)
fi
if [ -d "$SPARKLE_FRAMEWORK" ]; then
    cp -R "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/"
    echo "    Embedded Sparkle.framework from: $SPARKLE_FRAMEWORK"
else
    echo "    ERROR: Sparkle.framework not found in build artifacts"
    exit 1
fi
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

# Codesign: frameworks first, then app bundle
echo "==> Codesigning with Developer ID..."
codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc"
codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"
codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
echo "    Signed with: $SIGN_IDENTITY"

# Verify signature
codesign --verify --deep --strict "$APP_BUNDLE"
echo "    Signature verified"

if $NOTARIZE; then
    # Zip for notarization
    echo "==> Zipping for notarization..."
    rm -f "$ZIP_PATH"
    ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

    # Submit for notarization
    echo "==> Submitting for notarization (this may take a few minutes)..."
    xcrun notarytool submit "$ZIP_PATH" \
        --keychain-profile "$NOTARIZE_PROFILE" \
        --wait

    # Staple the ticket
    echo "==> Stapling notarization ticket..."
    xcrun stapler staple "$APP_BUNDLE"

    # Re-zip with stapled ticket for distribution
    echo "==> Creating distribution zip..."
    rm -f "$ZIP_PATH"
    ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

    echo ""
    echo "==> Done! Signed + notarized app bundle at:"
    echo "    $APP_BUNDLE"
    echo "    $ZIP_PATH (ready for distribution)"
else
    echo ""
    echo "==> Done! Signed app bundle at:"
    echo "    $APP_BUNDLE"
    echo ""
    echo "    To notarize: $0 --notarize"
    echo "    To install:  cp -R \"$APP_BUNDLE\" /Applications/"
    echo "    To run:      open \"$APP_BUNDLE\""
fi
