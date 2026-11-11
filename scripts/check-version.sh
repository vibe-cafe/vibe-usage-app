#!/bin/bash
set -euo pipefail

# Validates that the marketing version is consistent across the three places it
# lives, and that the build number is a monotonically increasing integer.
#
# Run standalone, or via build-app.sh (which calls this first).
#   ./scripts/check-version.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

APPCONFIG="$PROJECT_DIR/VibeUsage/Models/AppConfig.swift"
INFOPLIST="$PROJECT_DIR/VibeUsage/Info.plist"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

[[ -f "$APPCONFIG" ]] || fail "missing $APPCONFIG"
[[ -f "$INFOPLIST" ]] || fail "missing $INFOPLIST"

CONFIG_VERSION=$(grep -E 'static let version' "$APPCONFIG" \
    | sed -E 's/.*"([^"]+)".*/\1/')

PLIST_SHORT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFOPLIST")
PLIST_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFOPLIST")

echo "AppConfig.version              = $CONFIG_VERSION"
echo "CFBundleShortVersionString    = $PLIST_SHORT"
echo "CFBundleVersion (build)        = $PLIST_BUILD"

if [[ "$CONFIG_VERSION" != "$PLIST_SHORT" ]]; then
    fail "AppConfig.version ($CONFIG_VERSION) != CFBundleShortVersionString ($PLIST_SHORT)"
fi

if ! [[ "$PLIST_BUILD" =~ ^[0-9]+$ ]]; then
    fail "CFBundleVersion ($PLIST_BUILD) must be a plain integer — Sparkle compares it numerically"
fi

# If we're in a git checkout, make sure the build number advanced past the last
# tagged release. Prevents the "released without bumping CFBundleVersion" foot-gun.
if git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    LAST_TAG=$(git -C "$PROJECT_DIR" describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)
    if [[ -n "$LAST_TAG" ]]; then
        # PlistBuddy cannot read a plist from stdin, so this uses plutil. A tag
        # whose build number cannot be read is an error, not a skipped check.
        LAST_BUILD=$(git -C "$PROJECT_DIR" show "$LAST_TAG:VibeUsage/Info.plist" \
            | plutil -extract CFBundleVersion raw -o - -) \
            || fail "could not read CFBundleVersion from $LAST_TAG:VibeUsage/Info.plist"
        if ! [[ "$LAST_BUILD" =~ ^[0-9]+$ ]]; then
            fail "CFBundleVersion in $LAST_TAG ($LAST_BUILD) is not a plain integer"
        fi
        if (( PLIST_BUILD <= LAST_BUILD )); then
            fail "CFBundleVersion ($PLIST_BUILD) must be greater than last tag $LAST_TAG ($LAST_BUILD) — Sparkle won't detect the update otherwise"
        fi
    fi
fi

echo "Version check OK."
