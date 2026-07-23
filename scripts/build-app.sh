#!/bin/bash
set -euo pipefail

# Build Vibe Usage.app from SPM release binary
# Usage:
#   ./scripts/build-app.sh [--notarize] [--universal]
#   ./scripts/build-app.sh [--notarize] [--arch arm64] [--arch x86_64]
#
# --universal is shorthand for --arch arm64 --arch x86_64 (fat/universal binary).
# Omit --arch/--universal to build the host architecture only (faster local builds).
# Release builds should use --universal so Intel and Apple Silicon Macs both work.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="Vibe Usage"
BUNDLE_ID="ai.vibecafe.vibe-usage"
EXECUTABLE="VibeUsage"
DIST_DIR="$PROJECT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
ZIP_PATH="$DIST_DIR/VibeUsage.zip"
DMG_PATH="$DIST_DIR/VibeUsage.dmg"
ICON_SOURCE_DIR="$PROJECT_DIR/VibeUsage/Resources/Assets.xcassets/AppIcon.appiconset"
SIGN_IDENTITY="Developer ID Application: Yin Ming (D33463FWDZ)"
NOTARIZE_PROFILE="VibeUsage"
# Matches Package.swift platforms: .macOS(.v14)
MACOS_DEPLOYMENT_TARGET="14.0"

NOTARIZE=false
UNIVERSAL=false
ARCHS=()

usage() {
    cat <<EOF
Usage: $0 [--notarize] [--universal]
       $0 [--notarize] [--arch <arch>]...

Options:
  --notarize          Notarize the signed app + DMG (requires Developer ID)
  --universal         Build a universal (arm64 + x86_64) binary
  --arch <arch>       Build for architecture (repeatable: arm64, x86_64)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --notarize)
            NOTARIZE=true
            shift
            ;;
        --universal)
            UNIVERSAL=true
            shift
            ;;
        --arch)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --arch requires a value (arm64 or x86_64)" >&2
                exit 1
            fi
            case "$2" in
                arm64|x86_64) ;;
                *)
                    echo "ERROR: unsupported architecture '$2' (expected arm64 or x86_64)" >&2
                    exit 1
                    ;;
            esac
            ARCHS+=("$2")
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown option '$1'" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if $UNIVERSAL; then
    if [[ ${#ARCHS[@]} -gt 0 ]]; then
        echo "ERROR: use either --universal or --arch, not both" >&2
        exit 1
    fi
    ARCHS=(arm64 x86_64)
fi

# Deduplicate while preserving order
if [[ ${#ARCHS[@]} -gt 0 ]]; then
    DEDUPED=()
    for arch in "${ARCHS[@]}"; do
        seen=false
        for existing in "${DEDUPED[@]+"${DEDUPED[@]}"}"; do
            if [[ "$existing" == "$arch" ]]; then
                seen=true
                break
            fi
        done
        if ! $seen; then
            DEDUPED+=("$arch")
        fi
    done
    ARCHS=("${DEDUPED[@]}")
fi

# Fall back to ad-hoc signing when Developer ID is unavailable (e.g. local dev install).
# Notarization obviously cannot work in that mode, and hardened runtime's library
# validation rejects ad-hoc dylib loads across bundles, so the ad-hoc path also
# drops --options runtime.
#
# Identity detection captures the keychain listing into a variable first, rather than
# piping into `grep -q`: under `set -o pipefail`, grep exits on first match and
# `security` gets SIGPIPE (141), which would mark the pipeline failed and silently
# switch a valid Developer ID build to ad-hoc.
IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null || true)
if printf '%s\n' "$IDENTITIES" | grep -Fq -- "$SIGN_IDENTITY"; then
    codesign_args=(--force --options runtime --timestamp --sign "$SIGN_IDENTITY")
else
    if $NOTARIZE; then
        echo "ERROR: --notarize requires Developer ID ('$SIGN_IDENTITY') but it is not in the keychain." >&2
        exit 1
    fi
    echo "==> Developer ID not found — falling back to ad-hoc signing."
    SIGN_IDENTITY="-"
    codesign_args=(--force --sign "$SIGN_IDENTITY")
fi

echo "==> Checking version sync..."
"$SCRIPT_DIR/check-version.sh"

cd "$PROJECT_DIR"

# Prefer SwiftPM --arch when available (Xcode toolchain); otherwise --triple (CLT).
SWIFT_SUPPORTS_ARCH=false
if swift build --help 2>&1 | grep -q -- '--arch'; then
    SWIFT_SUPPORTS_ARCH=true
fi

arch_bin_dir() {
    local arch="$1"
    echo "$PROJECT_DIR/.build/${arch}-apple-macosx/release"
}

build_host() {
    echo "==> Building release binary (host architecture)..."
    swift build -c release
}

build_arch() {
    local arch="$1"
    echo "==> Building release binary ($arch)..."
    if $SWIFT_SUPPORTS_ARCH; then
        swift build -c release --arch "$arch"
    else
        swift build -c release --triple "${arch}-apple-macosx${MACOS_DEPLOYMENT_TARGET}"
    fi
}

STAGING_BIN="$(mktemp -t vibe-usage-bin)"
RESOURCE_BUILD_DIR=""

if [[ ${#ARCHS[@]} -eq 0 ]]; then
    build_host
    HOST_BUILD_DIR="$PROJECT_DIR/.build/release"
    if [[ ! -f "$HOST_BUILD_DIR/$EXECUTABLE" ]]; then
        echo "ERROR: missing executable at $HOST_BUILD_DIR/$EXECUTABLE" >&2
        exit 1
    fi
    cp "$HOST_BUILD_DIR/$EXECUTABLE" "$STAGING_BIN"
    RESOURCE_BUILD_DIR="$HOST_BUILD_DIR"
elif [[ ${#ARCHS[@]} -eq 1 ]]; then
    arch="${ARCHS[0]}"
    build_arch "$arch"
    ARCH_DIR="$(arch_bin_dir "$arch")"
    if [[ ! -f "$ARCH_DIR/$EXECUTABLE" ]]; then
        echo "ERROR: missing $arch executable at $ARCH_DIR/$EXECUTABLE" >&2
        exit 1
    fi
    cp "$ARCH_DIR/$EXECUTABLE" "$STAGING_BIN"
    RESOURCE_BUILD_DIR="$ARCH_DIR"
else
    LIPO_INPUTS=()
    for arch in "${ARCHS[@]}"; do
        build_arch "$arch"
        ARCH_DIR="$(arch_bin_dir "$arch")"
        if [[ ! -f "$ARCH_DIR/$EXECUTABLE" ]]; then
            echo "ERROR: missing $arch executable at $ARCH_DIR/$EXECUTABLE" >&2
            exit 1
        fi
        LIPO_INPUTS+=("$ARCH_DIR/$EXECUTABLE")
        if [[ -z "$RESOURCE_BUILD_DIR" ]]; then
            RESOURCE_BUILD_DIR="$ARCH_DIR"
        fi
    done
    echo "==> Creating universal binary (${ARCHS[*]})..."
    lipo -create "${LIPO_INPUTS[@]}" -output "$STAGING_BIN"
fi

echo "    Binary architectures: $(lipo -archs "$STAGING_BIN" 2>/dev/null || lipo -info "$STAGING_BIN")"

echo "==> Creating .app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Embed Sparkle.framework
echo "==> Embedding Sparkle.framework..."
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
SPARKLE_FRAMEWORK=$(find "$PROJECT_DIR/.build/artifacts" -name "Sparkle.framework" -path "*/macos-*" 2>/dev/null | head -1)
if [ -z "$SPARKLE_FRAMEWORK" ]; then
    SPARKLE_FRAMEWORK=$(find "$PROJECT_DIR/.build" -name "Sparkle.framework" -not -path "*/Sparkle.framework/Versions/*" 2>/dev/null | head -1)
fi
if [ -d "$SPARKLE_FRAMEWORK" ]; then
    cp -R "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/"
    echo "    Embedded Sparkle.framework from: $SPARKLE_FRAMEWORK"
else
    echo "    ERROR: Sparkle.framework not found in build artifacts"
    exit 1
fi
cp "$STAGING_BIN" "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE"
rm -f "$STAGING_BIN"
chmod +x "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE"

cp "$PROJECT_DIR/VibeUsage/Info.plist" "$APP_BUNDLE/Contents/"

RESOURCE_BUNDLE="$RESOURCE_BUILD_DIR/VibeUsage_VibeUsage.bundle"
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
    # macOS BSD mktemp requires an explicit template to end with at least six Xs;
    # `-t` sidesteps that by letting mktemp generate the random suffix itself.
    ENT=$(mktemp -t vibe-usage-ent) || { echo "mktemp failed" >&2; exit 1; }
    codesign -d --entitlements :- "$BIN" > "$ENT" 2>/dev/null || true
    if [ -s "$ENT" ] && grep -q '<key>' "$ENT" 2>/dev/null; then
        codesign "${codesign_args[@]}" --entitlements "$ENT" "$BIN"
    else
        codesign "${codesign_args[@]}" "$BIN"
    fi
    [ -n "$ENT" ] && rm -f "$ENT"
done
codesign "${codesign_args[@]}" "$SPARKLE_FW"
codesign "${codesign_args[@]}" "$APP_BUNDLE"
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
    echo "    Architectures: $(lipo -archs "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE" 2>/dev/null || true)"
    echo ""
    echo "    To notarize (universal): $0 --universal --notarize"
    echo "    To install:  cp -R \"$APP_BUNDLE\" /Applications/"
    echo "    To run:      open \"$APP_BUNDLE\""
fi
