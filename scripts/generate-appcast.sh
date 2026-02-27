#!/bin/bash
set -euo pipefail

# Generate appcast.xml for Sparkle auto-update.
# Run AFTER build-app.sh --notarize creates the signed+notarized ZIP.
#
# Prerequisites:
#   1. Ed25519 private key in Keychain (created via Sparkle's generate_keys)
#   2. dist/Vibe Usage.zip exists (signed + notarized)
#
# Usage: ./scripts/generate-appcast.sh
#
# Output: dist/appcast.xml — upload this alongside the ZIP to GitHub Releases.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$PROJECT_DIR/dist"

if [ ! -f "$DIST_DIR/Vibe Usage.zip" ]; then
    echo "ERROR: dist/Vibe Usage.zip not found."
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

echo "==> Generating appcast.xml..."
echo "    Using: $GENERATE_APPCAST"
echo "    Source: $DIST_DIR"

# generate_appcast scans the directory for ZIPs and creates/updates appcast.xml.
# It reads Ed25519 key from Keychain automatically.
"$GENERATE_APPCAST" "$DIST_DIR"

if [ -f "$DIST_DIR/appcast.xml" ]; then
    echo "==> Done! appcast.xml generated at:"
    echo "    $DIST_DIR/appcast.xml"
    echo ""
    echo "Upload both files to GitHub Release:"
    echo "    - dist/Vibe Usage.zip"
    echo "    - dist/appcast.xml"
else
    echo "ERROR: appcast.xml was not generated."
    exit 1
fi
