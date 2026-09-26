#!/bin/bash
set -euo pipefail

# Generate appcast.xml for Sparkle auto-update.
# Run AFTER build-app.sh --notarize creates the signed+notarized ZIP.
#
# Prerequisites:
#   1. Ed25519 private key in Keychain (created via Sparkle's generate_keys)
#   2. dist/VibeUsage.zip exists (signed + notarized)
#
# Usage: ./scripts/generate-appcast.sh
#
# Output: dist/appcast.xml — upload this alongside the ZIP to GitHub Releases.
#
# Enclosure URLs are pinned to the immutable per-release GitHub asset path
# (releases/download/v<version>/VibeUsage.zip), never to the "latest" alias
# (releases/latest/download/VibeUsage.zip). SUFeedURL itself still points at
# the "latest" alias to fetch appcast.xml — that part is fine, since the feed
# document is re-fetched fresh every time. But `generate_appcast` reuses and
# rewrites the existing appcast.xml in place, so any old item whose enclosure
# URL was left pointing at "latest" keeps pointing at "latest" forever. Once a
# newer release ships, GitHub repoints that alias at the new asset, and the
# old item's EdDSA signature (computed over the old ZIP bytes) no longer
# matches the bytes "latest" now serves. A user on an older version who
# updates during that window gets Sparkle's "The update is improperly signed
# and could not be validated." (confirmed 2026-09-18: a user hit this at
# 17:37 the day 0.6.2 shipped; openssl independently verified the 0.6.1 item's
# signature fails against what "latest" serves post-0.6.2, and succeeds
# against releases/download/v0.6.1/VibeUsage.zip).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$PROJECT_DIR/dist"
INFOPLIST="$PROJECT_DIR/VibeUsage/Info.plist"
REPO_RELEASES_URL="https://github.com/vibe-cafe/vibe-usage-app/releases"

if [ ! -f "$DIST_DIR/VibeUsage.zip" ]; then
    echo "ERROR: dist/VibeUsage.zip not found."
    echo "       Run ./scripts/build-app.sh --notarize first."
    exit 1
fi

# Find generate_appcast from Sparkle's SPM artifacts
GENERATE_APPCAST=$(find "$PROJECT_DIR/.build/artifacts" -name "generate_appcast" -type f | head -1)
if [ -z "$GENERATE_APPCAST" ]; then
    echo "ERROR: generate_appcast not found in .build/artifacts"
    echo "       Run 'swift build -c release' first to download Sparkle."
    exit 1
fi

# Tag defaults to v<CFBundleShortVersionString>, matching the tag naming
# build-app.sh's release flow and every existing GitHub release use
# (v0.6.2, v0.6.1, v0.5.10, ...). Override with APPCAST_TAG if a release is
# ever cut under a different tag.
if [ -n "${APPCAST_TAG:-}" ]; then
    TAG="$APPCAST_TAG"
else
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFOPLIST")
    if [ -z "$VERSION" ]; then
        echo "ERROR: could not read CFBundleShortVersionString from $INFOPLIST"
        exit 1
    fi
    TAG="v$VERSION"
fi
DOWNLOAD_URL_PREFIX="$REPO_RELEASES_URL/download/$TAG/"

echo "==> Generating appcast.xml..."
echo "    Using: $GENERATE_APPCAST"
echo "    Source: $DIST_DIR"
echo "    Download URL prefix (this run's new item): $DOWNLOAD_URL_PREFIX"

# generate_appcast scans the directory for archives. Temporarily hide the DMG
# to avoid "duplicate version" errors (DMG is for initial download, ZIP for updates).
DMG_PATH="$DIST_DIR/VibeUsage.dmg"
if [ -f "$DMG_PATH" ]; then
    mv "$DMG_PATH" "$DMG_PATH.bak"
fi
"$GENERATE_APPCAST" --download-url-prefix "$DOWNLOAD_URL_PREFIX" "$DIST_DIR"
if [ -f "$DMG_PATH.bak" ]; then
    mv "$DMG_PATH.bak" "$DMG_PATH"
fi

if [ ! -f "$DIST_DIR/appcast.xml" ]; then
    echo "ERROR: appcast.xml was not generated."
    exit 1
fi

# --download-url-prefix only affects the item(s) generate_appcast creates in
# this run. generate_appcast reuses and rewrites the existing appcast.xml, so
# any older item already carrying the "latest" alias URL is left untouched by
# the flag above. Rewrite those in place, keyed off the release version each
# item already declares (sparkle:shortVersionString), before this appcast.xml
# is published.
echo "==> Rewriting any legacy 'latest' enclosure URLs to per-tag URLs..."
python3 "$SCRIPT_DIR/rewrite-appcast-enclosures.py" "$DIST_DIR/appcast.xml" "$REPO_RELEASES_URL"

echo "==> Done! appcast.xml generated at:"
echo "    $DIST_DIR/appcast.xml"
echo ""
echo "Upload both files to GitHub Release:"
echo "    - dist/VibeUsage.zip"
echo "    - dist/appcast.xml"
