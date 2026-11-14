#!/bin/bash
set -euo pipefail

# Build Vibe Usage.app from SPM release binary
# Usage:
#   ./scripts/build-app.sh [--notarize] [--universal] [--external-test --cli-source <path>]
#   ./scripts/build-app.sh [--notarize] [--arch arm64] [--arch x86_64] [--external-test --cli-source <path>]
#
# --universal is shorthand for --arch arm64 --arch x86_64 (fat/universal binary).
# Omit --arch/--universal to build the host architecture only (faster local builds).
# Release builds should use --universal so Intel and Apple Silicon Macs both work.
# --external-test keeps the production service/config behavior of a Release build,
# while compiling in the local, redacted diagnostic exporter for test packages.
#
# Ordinary builds bundle the pinned official Node.js at Contents/Helpers/node
# (scripts/fetch-node.sh, scripts/bundled-node.env), sign it with the two JIT
# entitlements in scripts/node.entitlements, and check that this signed copy
# runs the CLI launcher (VibeUsage/Resources/cli-bootstrap.mjs) and the CLI
# contract gate. External-test builds keep running their embedded CLI through
# the system npx and carry no Node.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="Vibe Usage"
BUNDLE_ID="ai.vibecafe.vibe-usage"
EXECUTABLE="VibeUsage"
DIST_DIR="$PROJECT_DIR/dist"
ICON_SOURCE_DIR="$PROJECT_DIR/VibeUsage/Resources/Assets.xcassets/AppIcon.appiconset"
SIGN_IDENTITY="Developer ID Application: JIANZHONG ZHAO (8HGCD674ZS)"
NOTARIZE_PROFILE="VibeUsage-8HGCD674ZS"
# Matches Package.swift platforms: .macOS(.v14)
MACOS_DEPLOYMENT_TARGET="14.0"

NOTARIZE=false
AD_HOC=false
UNIVERSAL=false
EXTERNAL_TEST=false
CLI_SOURCE=""
ARCHS=()

usage() {
    cat <<EOF
Usage: $0 [--notarize | --ad-hoc] [--universal] [--external-test --cli-source <path>]
       $0 [--notarize | --ad-hoc] [--arch <arch>]... [--external-test --cli-source <path>]

Options:
  --notarize          Notarize the signed app + DMG (requires Developer ID)
  --ad-hoc            Sign ad hoc even when the Developer ID is in the keychain
                      (local tests and rehearsals that must not use it)
  --universal         Build a universal (arm64 + x86_64) binary
  --arch <arch>       Build for architecture (repeatable: arm64, x86_64)
  --external-test     Release-mode app with redacted local test diagnostics
  --cli-source <path> Clean vibe-usage checkout to embed in an external test
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --notarize)
            NOTARIZE=true
            shift
            ;;
        --ad-hoc)
            AD_HOC=true
            shift
            ;;
        --universal)
            UNIVERSAL=true
            shift
            ;;
        --external-test)
            EXTERNAL_TEST=true
            shift
            ;;
        --cli-source)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --cli-source requires a path" >&2
                exit 1
            fi
            CLI_SOURCE="$2"
            shift 2
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

if $NOTARIZE && $AD_HOC; then
    echo "ERROR: --notarize and --ad-hoc cannot be combined" >&2
    exit 1
fi

if $EXTERNAL_TEST; then
    if [[ -z "$CLI_SOURCE" ]]; then
        echo "ERROR: --external-test requires --cli-source <path>" >&2
        exit 1
    fi
    if [[ ! -d "$CLI_SOURCE" ]]; then
        echo "ERROR: CLI source directory not found: $CLI_SOURCE" >&2
        exit 1
    fi
    CLI_SOURCE=$(cd "$CLI_SOURCE" && pwd)
    if [[ ! -f "$CLI_SOURCE/package.json" ]]; then
        echo "ERROR: CLI package.json not found under: $CLI_SOURCE" >&2
        exit 1
    fi
    if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
        echo "ERROR: external-test packaging requires node and npm" >&2
        exit 1
    fi
    CLI_PACKAGE_NAME=$(node -e 'const p=require(process.argv[1]); process.stdout.write(p.name)' "$CLI_SOURCE/package.json")
    if [[ "$CLI_PACKAGE_NAME" != "@vibe-cafe/vibe-usage" ]]; then
        echo "ERROR: unexpected CLI package name: $CLI_PACKAGE_NAME" >&2
        exit 1
    fi
    if [[ -n "$(git -C "$CLI_SOURCE" status --porcelain)" ]]; then
        echo "ERROR: CLI source must be clean so the embedded package is reproducible" >&2
        exit 1
    fi
    CLI_VERSION=$(node -e 'const p=require(process.argv[1]); process.stdout.write(p.version)' "$CLI_SOURCE/package.json")
    CLI_COMMIT=$(git -C "$CLI_SOURCE" rev-parse --short=12 HEAD)
    if [[ -n "$(git -C "$PROJECT_DIR" status --porcelain)" ]]; then
        echo "ERROR: app source must be clean so the external build is traceable" >&2
        exit 1
    fi
    APP_COMMIT=$(git -C "$PROJECT_DIR" rev-parse --short=12 HEAD)
    APP_NAME="Vibe Usage Test"
    BUNDLE_ID="ai.vibecafe.vibe-usage.external-test"
elif [[ -n "$CLI_SOURCE" ]]; then
    echo "ERROR: --cli-source is valid only with --external-test" >&2
    exit 1
fi

APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
if $EXTERNAL_TEST; then
    ZIP_PATH="$DIST_DIR/VibeUsage-Test.zip"
    DMG_PATH="$DIST_DIR/VibeUsage-Test.dmg"
else
    ZIP_PATH="$DIST_DIR/VibeUsage.zip"
    DMG_PATH="$DIST_DIR/VibeUsage.dmg"
fi

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

# Check before compilation, signing, or replacing existing artifacts. A local
# CLI override must never stand in for the published dependency of a normal app.
echo "==> Checking CLI package contract..."
if $EXTERNAL_TEST; then
    node "$SCRIPT_DIR/check-cli.mjs" --from-local "$CLI_SOURCE"
else
    node "$SCRIPT_DIR/check-cli.mjs"
fi

# The launcher is owned by the Windows repository; a release must ship exactly
# what its main branch has. Other builds only warn.
echo "==> Checking CLI launcher against vibe-usage-windows..."
if $NOTARIZE && ! $EXTERNAL_TEST; then
    "$SCRIPT_DIR/check-cli-bootstrap.sh" --sibling
elif ! "$SCRIPT_DIR/check-cli-bootstrap.sh" --sibling; then
    echo "    WARNING: launcher differs from vibe-usage-windows main (or the checkout is missing); a release build would stop here."
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
IDENTITIES=""
if ! $AD_HOC; then
    IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null || true)
fi
if printf '%s\n' "$IDENTITIES" | grep -Fq -- "$SIGN_IDENTITY"; then
    codesign_args=(--force --options runtime --timestamp --sign "$SIGN_IDENTITY")
else
    if $NOTARIZE; then
        echo "ERROR: --notarize requires Developer ID ('$SIGN_IDENTITY') but it is not in the keychain." >&2
        exit 1
    fi
    if $AD_HOC; then
        echo "==> --ad-hoc: signing ad hoc."
    else
        echo "==> Developer ID not found — falling back to ad-hoc signing."
    fi
    SIGN_IDENTITY="-"
    codesign_args=(--force --sign "$SIGN_IDENTITY")
fi

echo "==> Checking version sync..."
# Only a notarized production build is a release: it must carry a build number
# above the last v* tag. Local, ad-hoc, and external-test builds (including a
# notarized external test) happen between releases, so that rule only warns.
if $NOTARIZE && ! $EXTERNAL_TEST; then
    "$SCRIPT_DIR/check-version.sh"
else
    "$SCRIPT_DIR/check-version.sh" --non-release
fi

cd "$PROJECT_DIR"

# Temporary paths registered here are removed on every exit, including a check
# that stops the build half-way.
TEMP_PATHS=()
cleanup_temp_paths() {
    local path
    for path in ${TEMP_PATHS[@]+"${TEMP_PATHS[@]}"}; do
        rm -rf "$path"
    done
}
trap cleanup_temp_paths EXIT

SWIFT_BUILD_ARGS=()
if $EXTERNAL_TEST; then
    SWIFT_BUILD_ARGS=(-Xswiftc -D -Xswiftc VIBE_USAGE_EXTERNAL_TEST)
    echo "==> External-test diagnostics enabled (production API/config unchanged)."
fi

# Xcode 27 (Swift 6.4) made SwiftPM's "swiftbuild" engine the default, which
# writes per-arch products to .build/out/Products/Release instead of
# .build/<arch>-apple-macosx/release. Releases up to 0.7.4 were built with the
# native build system and the paths below follow its layout, so select it
# explicitly whenever the toolchain offers the choice.
if swift build --help 2>&1 | grep -q -- '--build-system'; then
    SWIFT_BUILD_ARGS+=(--build-system native)
fi

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
    swift build -c release ${SWIFT_BUILD_ARGS[@]+"${SWIFT_BUILD_ARGS[@]}"}
}

build_arch() {
    local arch="$1"
    echo "==> Building release binary ($arch)..."
    if $SWIFT_SUPPORTS_ARCH; then
        swift build -c release --arch "$arch" ${SWIFT_BUILD_ARGS[@]+"${SWIFT_BUILD_ARGS[@]}"}
    else
        swift build -c release --triple "${arch}-apple-macosx${MACOS_DEPLOYMENT_TARGET}" ${SWIFT_BUILD_ARGS[@]+"${SWIFT_BUILD_ARGS[@]}"}
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
if $EXTERNAL_TEST; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$APP_BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$APP_BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Delete :SUPublicEDKey" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Delete :SUEnableAutomaticChecks" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Delete :SUAutomaticallyUpdate" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Delete :SUScheduledCheckInterval" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :VibeUsageBuildKind string external-test" "$APP_BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :VibeUsageAppCommit string $APP_COMMIT" "$APP_BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :VibeUsageCLICommit string $CLI_COMMIT" "$APP_BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :VibeUsageCLIVersion string $CLI_VERSION" "$APP_BUNDLE/Contents/Info.plist"
fi

RESOURCE_BUNDLE="$RESOURCE_BUILD_DIR/VibeUsage_VibeUsage.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
    cp -R "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
    echo "    Copied SPM resource bundle"
else
    echo "    WARNING: SPM resource bundle not found at $RESOURCE_BUNDLE"
fi

LAUNCHER_IN_APP=$(find "$APP_BUNDLE/Contents/Resources/VibeUsage_VibeUsage.bundle" -name cli-bootstrap.mjs -print -quit 2>/dev/null || true)
if [[ -z "$LAUNCHER_IN_APP" ]] || ! cmp -s "$LAUNCHER_IN_APP" "$PROJECT_DIR/VibeUsage/Resources/cli-bootstrap.mjs"; then
    echo "ERROR: the resource bundle does not carry VibeUsage/Resources/cli-bootstrap.mjs unchanged" >&2
    exit 1
fi

NODE_BIN="$APP_BUNDLE/Contents/Helpers/node"
if ! $EXTERNAL_TEST; then
    NODE_ARCH_ARGS=()
    for arch in "${ARCHS[@]+"${ARCHS[@]}"}"; do
        NODE_ARCH_ARGS+=(--arch "$arch")
    done
    "$SCRIPT_DIR/fetch-node.sh" --output "$NODE_BIN" ${NODE_ARCH_ARGS[@]+"${NODE_ARCH_ARGS[@]}"}
fi

if $EXTERNAL_TEST; then
    echo "==> Packing embedded CLI ($CLI_VERSION at $CLI_COMMIT)..."
    CLI_PACK_DIR=$(mktemp -d)
    npm pack "$CLI_SOURCE" --pack-destination "$CLI_PACK_DIR" >/dev/null
    CLI_PACKAGE=$(find "$CLI_PACK_DIR" -maxdepth 1 -type f -name '*.tgz' -print -quit)
    if [[ -z "$CLI_PACKAGE" ]]; then
        echo "ERROR: npm pack did not produce a CLI tarball" >&2
        rm -rf "$CLI_PACK_DIR"
        exit 1
    fi
    cp "$CLI_PACKAGE" "$APP_BUNDLE/Contents/Resources/vibe-usage-cli.tgz"
    rm -rf "$CLI_PACK_DIR"
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

# Codesign inside-out: the bundled Node, all Sparkle internals, the framework,
# then the app. Extract Sparkle's entitlements first to avoid
# --preserve-metadata timestamp errors.
echo "==> Codesigning ($SIGN_IDENTITY)..."
if [[ -f "$NODE_BIN" ]]; then
    # Replaces the Node.js project's own signature (its get-task-allow would fail
    # notarization) with ours and only the two JIT entitlements.
    codesign "${codesign_args[@]}" --identifier "ai.vibecafe.vibe-usage.node" \
        --entitlements "$SCRIPT_DIR/node.entitlements" "$NODE_BIN"
fi
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
    TEMP_PATHS+=("$ENT")
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

if [[ -f "$NODE_BIN" ]]; then
    echo "==> Checking the bundled Node..."
    NODE_ENTITLEMENTS=$(codesign -d --entitlements - --xml "$NODE_BIN" 2>/dev/null || true)
    if printf '%s' "$NODE_ENTITLEMENTS" | grep -q 'get-task-allow'; then
        echo "ERROR: the bundled Node carries get-task-allow; notarization would reject it" >&2
        exit 1
    fi
    if [[ "$SIGN_IDENTITY" != "-" ]] && ! printf '%s' "$NODE_ENTITLEMENTS" | grep -q 'com.apple.security.cs.allow-jit'; then
        echo "ERROR: the bundled Node is missing allow-jit; it would be killed at start-up" >&2
        exit 1
    fi
    # shellcheck source=bundled-node.env
    source "$SCRIPT_DIR/bundled-node.env"
    NODE_CHECK_DIR=$(mktemp -d -t vibe-usage-node-check)
    TEMP_PATHS+=("$NODE_CHECK_DIR")
    # The app's own start-up probe, the shipped launcher (in an empty home and
    # cache, so the official registry is asked and the user's cache is left
    # alone), and the CLI contract gate run by this signed Node.
    check_bundled_node() {
        local label="$1"; shift
        local probe cli_version
        probe=$("$@" "$NODE_BIN" -e 'let s=0;for(let i=0;i<2e6;i++)s+=i%7;process.stdout.write(process.version)') \
            || probe="a failure (exit $?)"
        if [[ "$probe" != "v$NODE_VERSION" ]]; then
            echo "ERROR: bundled Node ($label) answered $probe, expected v$NODE_VERSION" >&2
            exit 1
        fi
        mkdir -p "$NODE_CHECK_DIR/$label"
        cli_version=$(HOME="$NODE_CHECK_DIR/$label" VIBE_USAGE_CONFIG_DIR="$NODE_CHECK_DIR/$label" \
            "$@" "$NODE_BIN" "$LAUNCHER_IN_APP" --version)
        echo "    $label: probe $probe, launcher ran CLI $cli_version"
        "$@" "$NODE_BIN" "$SCRIPT_DIR/check-cli.mjs"
    }
    NODE_ARCHS=$(lipo -archs "$NODE_BIN")
    if [[ " $NODE_ARCHS " == *" $(uname -m) "* ]]; then
        check_bundled_node "$(uname -m)" env
    fi
    # On Apple silicon, run the Intel slice under Rosetta too (only a proxy for
    # a real Intel Mac: Rosetta's memory protection differs).
    if [[ "$(uname -m)" == "arm64" && " $NODE_ARCHS " == *" x86_64 "* ]]; then
        if arch -x86_64 /usr/bin/true 2>/dev/null; then
            check_bundled_node x86_64-rosetta arch -x86_64
        elif $NOTARIZE; then
            echo "ERROR: Rosetta is not installed, so the Intel slice of the bundled Node cannot be checked" >&2
            exit 1
        else
            echo "    WARNING: Rosetta is not installed; the Intel slice was not run."
        fi
    fi
    rm -rf "$NODE_CHECK_DIR"
fi

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
        -ov -format ULMO \
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
    echo "    $APP_BUNDLE ($(du -sh "$APP_BUNDLE" | awk '{ print $1 }') installed)"
    echo "    $DMG_PATH (initial download, $(stat -f %z "$DMG_PATH") bytes)"
    echo "    $ZIP_PATH (Sparkle updates, $(stat -f %z "$ZIP_PATH") bytes)"
else
    if $EXTERNAL_TEST; then
        echo "==> Creating external-test ZIP..."
        rm -f "$ZIP_PATH"
        ZIP_STAGING=$(mktemp -d)
        cp -R "$APP_BUNDLE" "$ZIP_STAGING/"
        cp "$PROJECT_DIR/docs/EXTERNAL_TESTING.zh-CN.md" "$ZIP_STAGING/外测说明.md"
        ditto -c -k --sequesterRsrc "$ZIP_STAGING" "$ZIP_PATH"
        rm -rf "$ZIP_STAGING"
    fi
    echo ""
    echo "==> Done! Signed app bundle at:"
    echo "    $APP_BUNDLE ($(du -sh "$APP_BUNDLE" | awk '{ print $1 }'))"
    echo "    Architectures: $(lipo -archs "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE" 2>/dev/null || true)"
    if $EXTERNAL_TEST; then
        echo "    Build kind: external test (redacted diagnostics enabled)"
        echo "    App commit: $APP_COMMIT"
        echo "    Embedded CLI: $CLI_VERSION ($CLI_COMMIT)"
        echo "    Shareable ZIP: $ZIP_PATH"
    fi
    echo ""
    echo "    To notarize (universal): $0 --universal --notarize"
    echo "    To install:  cp -R \"$APP_BUNDLE\" /Applications/"
    echo "    To run:      open \"$APP_BUNDLE\""
fi
