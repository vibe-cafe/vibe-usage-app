#!/bin/bash
set -euo pipefail

# The CLI launcher is owned by the Windows repository
# (vibe-cafe/vibe-usage-windows, src-tauri/resources/cli-bootstrap.mjs); this
# repository carries a byte-for-byte copy at VibeUsage/Resources/ (approved
# 2026-11-14, 《Mac 自带 Node 方案》§2.2). Change it there first, then copy it.
#
# Usage:
#   ./scripts/check-cli-bootstrap.sh --github <ref>   # CI: compare with that ref on GitHub
#   ./scripts/check-cli-bootstrap.sh --sibling        # release: compare with origin/main of
#                                                     # the vibe-usage-windows checkout beside
#                                                     # this repository (VIBE_USAGE_WINDOWS_REPO
#                                                     # overrides its location)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCAL="$PROJECT_DIR/VibeUsage/Resources/cli-bootstrap.mjs"
WINDOWS_PATH="src-tauri/resources/cli-bootstrap.mjs"

EXPECTED="$(mktemp -t vibe-usage-bootstrap)"
trap 'rm -f "$EXPECTED"' EXIT

case "${1:-}" in
    --github)
        [[ $# -eq 2 ]] || { echo "Usage: $0 --github <ref>" >&2; exit 1; }
        SOURCE="vibe-cafe/vibe-usage-windows@$2"
        curl -fsSL --retry 3 -o "$EXPECTED" \
            "https://raw.githubusercontent.com/vibe-cafe/vibe-usage-windows/$2/$WINDOWS_PATH"
        ;;
    --sibling)
        # In a worktree, the sibling sits next to the main checkout, not next to
        # the worktree directory.
        MAIN_CHECKOUT="$(cd "$(git -C "$PROJECT_DIR" rev-parse --path-format=absolute --git-common-dir)/.." && pwd)"
        WINDOWS_REPO="${VIBE_USAGE_WINDOWS_REPO:-$MAIN_CHECKOUT/../vibe-usage-windows}"
        if [[ ! -d "$WINDOWS_REPO/.git" && ! -f "$WINDOWS_REPO/.git" ]]; then
            echo "ERROR: vibe-usage-windows checkout not found at $WINDOWS_REPO (set VIBE_USAGE_WINDOWS_REPO)" >&2
            exit 1
        fi
        git -C "$WINDOWS_REPO" fetch --quiet origin main
        SOURCE="vibe-usage-windows origin/main ($(git -C "$WINDOWS_REPO" rev-parse --short origin/main))"
        git -C "$WINDOWS_REPO" show "origin/main:$WINDOWS_PATH" > "$EXPECTED"
        ;;
    *)
        echo "Usage: $0 --github <ref> | --sibling" >&2
        exit 1
        ;;
esac

if cmp -s "$EXPECTED" "$LOCAL"; then
    echo "    cli-bootstrap.mjs matches $SOURCE"
else
    echo "ERROR: VibeUsage/Resources/cli-bootstrap.mjs differs from $SOURCE." >&2
    echo "       The Windows repository owns this file: change it there, then copy it byte for byte." >&2
    exit 1
fi
