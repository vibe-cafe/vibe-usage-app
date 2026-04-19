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
ZIP_PATH="$DIST_DIR/VibeUsage.zip"
DMG_PATH="$DIST_DIR/VibeUsage.dmg"
ICON_SOURCE_DIR="$PROJECT_DIR/VibeUsage/Resources/Assets.xcassets/AppIcon.appiconset"
SIGN_IDENTITY="Developer ID Application: Yin Ming (D33463FWDZ)"
NOTARIZE_PROFILE="VibeUsage"

NOTARIZE=false
if [[ "${1:-}" == "--notarize" ]]; then
    NOTARIZE=true
fi

# Fall back to ad-hoc signing when Developer ID is unavailable (e.g. local dev install).
# Notarization obviously cannot work in that mode, and hardened runtime's library
# validation rejects ad-hoc dylib loads across bundles, so we drop --options runtime.
CS_EXTRA_FLAGS=("--timestamp")
CS_OPTIONS=("--options" "runtime")
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    if $NOTARIZE; then
        echo "ERROR: --notarize requires Developer ID ('$SIGN_IDENTITY') but it is not in the keychain." >&2
        exit 1
    fi
    echo "==> Developer ID not found — falling back to ad-hoc signing."
    SIGN_IDENTITY="-"
    CS_EXTRA_FLAGS=()
    CS_OPTIONS=()
fi

echo "==> Checking version sync..."
"$SCRIPT_DIR/check-version.sh"

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
    SPARKLE_FRAMEWORK=$(find "$PROJECT_DIR/.build" -name "Sparkle.framework" -not -path "*/Sparkle.framework/Versions/*" | head -1)
fi
if [ -d "$SPARKLE_FRAMEWORK" ]; then
    cp -R "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/"
    echo "    Embedded Sparkle.framework from: $SPARKLE_FRAMEWORK"
else
    echo "    ERROR: Sparkle.framework not found in build artifacts"
    exit 1
fi
cp "$BUILD_DIR/$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE"

cp "$PROJECT_DIR/VibeUsage/Info.plist" "$APP_BUNDLE/Contents/"

RESOURCE_BUNDLE="$BUILD_DIR/VibeUsage_VibeUsage.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
    cp -R "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
    echo "    Copied SPM resource bundle"
else
    echo "    WARNING: SPM resource bundle not found at $RESOURCE_BUNDLE"
fi

echo "==> Generating AppIcon.icns..."
ICONSET_DIR=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET_DIR"

cp "$ICON_SOURCE_DIR/icon_16x16.png"      "$ICONSET_DIR/icon_16x16.png"
cp "$ICON_SOURCE_DIR/icon_16x16@2x.png"   "$ICONSET_DIR/icon_16x16@2x.png"
cp "$ICON_SOURCE_DIR/icon_32x32.png"       "$ICONSET_DIR/icon_32x32.png"
cp "$ICON_SOURCE_DIR/icon_32x32@2x.png"    "$ICONSET_DIR/icon_32x32@2x.png"
cp "$ICON_SOURCE_DIR/icon_128x128.png"     "$ICONSET_DIR/icon_128x128.png"
cp "$ICON_SOURCE_DIR/icon_128x128@2x.png"  "$ICONSET_DIR/icon_128x128@2x.png"
cp "$ICON_SOURCE_DIR/icon_256x256.png"     "$ICONSET_DIR/icon_256x256.png"
cp "$ICON_SOURCE_DIR/icon_256x256@2x.png"  "$ICONSET_DIR/icon_256x256@2x.png"
cp "$ICON_SOURCE_DIR/icon_512x512.png"     "$ICONSET_DIR/icon_512x512.png"
cp "$ICON_SOURCE_DIR/icon_512x512@2x.png"  "$ICONSET_DIR/icon_512x512@2x.png"

iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET_DIR")"
echo "    Generated AppIcon.icns"

# Codesign: sign all Sparkle internals inside-out, then framework, then app
# Extract entitlements first to avoid --preserve-metadata timestamp errors
echo "==> Codesigning ($SIGN_IDENTITY)..."
SPARKLE_FW="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
SPARKLE_BINS=(
    "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc"
    "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc"
    "$SPARKLE_FW/Versions/B/Autoupdate"
    "$SPARKLE_FW/Versions/B/Updater.app"
)
for BIN in "${SPARKLE_BINS[@]}"; do
    [ -e "$BIN" ] || continue
    # BSD mktemp requires trailing Xs — keep the template simple, no suffix.
    ENT=$(mktemp -t vibe-usage-ent) || { echo "mktemp failed" >&2; exit 1; }
    codesign -d --entitlements :- "$BIN" > "$ENT" 2>/dev/null || true
    if [ -s "$ENT" ] && grep -q '<key>' "$ENT" 2>/dev/null; then
        codesign --force ${CS_OPTIONS[@]+"${CS_OPTIONS[@]}"} ${CS_EXTRA_FLAGS[@]+"${CS_EXTRA_FLAGS[@]}"} --sign "$SIGN_IDENTITY" --entitlements "$ENT" "$BIN"
    else
        codesign --force ${CS_OPTIONS[@]+"${CS_OPTIONS[@]}"} ${CS_EXTRA_FLAGS[@]+"${CS_EXTRA_FLAGS[@]}"} --sign "$SIGN_IDENTITY" "$BIN"
    fi
    [ -n "$ENT" ] && rm -f "$ENT"
done
codesign --force ${CS_OPTIONS[@]+"${CS_OPTIONS[@]}"} ${CS_EXTRA_FLAGS[@]+"${CS_EXTRA_FLAGS[@]}"} --sign "$SIGN_IDENTITY" "$SPARKLE_FW"
codesign --force ${CS_OPTIONS[@]+"${CS_OPTIONS[@]}"} ${CS_EXTRA_FLAGS[@]+"${CS_EXTRA_FLAGS[@]}"} --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
echo "    Signed with: $SIGN_IDENTITY"

codesign --verify --deep --strict "$APP_BUNDLE"

if $NOTARIZE; then
    # Zip for notarization submission
    echo "==> Zipping for notarization..."
    rm -f "$ZIP_PATH"
    ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"

    echo "==> Submitting for notarization (this may take a few minutes)..."
    xcrun notarytool submit "$ZIP_PATH" \
        --keychain-profile "$NOTARIZE_PROFILE" \
        --wait

    echo "==> Stapling notarization ticket..."
    xcrun stapler staple "$APP_BUNDLE"

    # Create distribution ZIP (for Sparkle auto-updates)
    echo "==> Creating Sparkle update zip..."
    rm -f "$ZIP_PATH"
    ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"

    # Create distribution DMG (for initial download)
    echo "==> Creating distribution DMG..."
    rm -f "$DMG_PATH"
    DMG_STAGING=$(mktemp -d)
    cp -R "$APP_BUNDLE" "$DMG_STAGING/"
    ln -s /Applications "$DMG_STAGING/Applications"

    hdiutil create -volname "$APP_NAME" \
        -srcfolder "$DMG_STAGING" \
        -ov -format UDZO \
        "$DMG_PATH"
    rm -rf "$DMG_STAGING"

    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"

    echo "==> Notarizing DMG..."
    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARIZE_PROFILE" \
        --wait
    xcrun stapler staple "$DMG_PATH"

    echo ""
    echo "==> Done! Signed + notarized:"
    echo "    $APP_BUNDLE"
    echo "    $DMG_PATH (initial download)"
    echo "    $ZIP_PATH (Sparkle updates)"
else
    echo ""
    echo "==> Done! Signed app bundle at:"
    echo "    $APP_BUNDLE"
    echo ""
    echo "    To notarize: $0 --notarize"
    echo "    To install:  cp -R \"$APP_BUNDLE\" /Applications/"
    echo "    To run:      open \"$APP_BUNDLE\""
fi
