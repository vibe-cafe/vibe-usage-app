#!/bin/bash
set -euo pipefail

# Download the pinned official Node.js build for each requested architecture,
# verify it twice, and write the `node` executable (universal when both
# architectures are requested).
#
# Usage:
#   ./scripts/fetch-node.sh --output <path> [--universal | --arch arm64 | --arch x86_64]...
#
# Without --arch/--universal the host architecture is used. Each tarball is
# accepted only when its SHA256 equals both the value in nodejs.org's
# SHASUMS256.txt and the value pinned in scripts/bundled-node.env, so neither a
# tampered mirror of the site nor a tampered checkout alone can slip a
# different binary in. Verified tarballs are kept in .build/bundled-node/ so a
# rebuild does not download them again (SHASUMS256.txt is fetched every time).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=bundled-node.env
source "$SCRIPT_DIR/bundled-node.env"

OUTPUT=""
ARCHS=()
CACHE_DIR="$PROJECT_DIR/.build/bundled-node/v$NODE_VERSION"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)
            [[ $# -ge 2 ]] || { echo "ERROR: --output requires a path" >&2; exit 1; }
            OUTPUT="$2"
            shift 2
            ;;
        --universal)
            ARCHS=(arm64 x86_64)
            shift
            ;;
        --arch)
            [[ $# -ge 2 ]] || { echo "ERROR: --arch requires a value (arm64 or x86_64)" >&2; exit 1; }
            case "$2" in
                arm64|x86_64) ARCHS+=("$2") ;;
                *) echo "ERROR: unsupported architecture '$2'" >&2; exit 1 ;;
            esac
            shift 2
            ;;
        *)
            echo "ERROR: unknown option '$1'" >&2
            exit 1
            ;;
    esac
done

[[ -n "$OUTPUT" ]] || { echo "ERROR: --output <path> is required" >&2; exit 1; }
if [[ ${#ARCHS[@]} -eq 0 ]]; then
    ARCHS=("$(uname -m)")
fi

mkdir -p "$CACHE_DIR"
WORK="$(mktemp -d -t vibe-usage-node)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Fetching Node.js v$NODE_VERSION (${ARCHS[*]})..."
curl -fsSL --retry 3 -o "$WORK/SHASUMS256.txt" "https://nodejs.org/dist/v$NODE_VERSION/SHASUMS256.txt"

THIN=()
for arch in "${ARCHS[@]}"; do
    case "$arch" in
        arm64) node_arch=arm64; pinned="$NODE_SHA256_DARWIN_ARM64" ;;
        x86_64) node_arch=x64; pinned="$NODE_SHA256_DARWIN_X64" ;;
    esac
    name="node-v$NODE_VERSION-darwin-$node_arch"
    tarball="$CACHE_DIR/$name.tar.xz"
    if [[ ! -f "$tarball" ]]; then
        curl -fL --retry 3 --progress-bar -o "$tarball.part" "https://nodejs.org/dist/v$NODE_VERSION/$name.tar.xz"
        mv "$tarball.part" "$tarball"
    fi

    published=$(awk -v file="$name.tar.xz" '$2 == file { print $1 }' "$WORK/SHASUMS256.txt")
    actual=$(shasum -a 256 "$tarball" | awk '{ print $1 }')
    if [[ -z "$published" || "$actual" != "$published" ]]; then
        rm -f "$tarball"
        echo "ERROR: $name.tar.xz does not match nodejs.org's SHASUMS256.txt (got $actual)" >&2
        exit 1
    fi
    if [[ "$actual" != "$pinned" ]]; then
        rm -f "$tarball"
        echo "ERROR: $name.tar.xz does not match the SHA256 pinned in scripts/bundled-node.env" >&2
        exit 1
    fi
    echo "    $name.tar.xz SHA256 OK ($actual)"

    mkdir -p "$WORK/$arch"
    tar -xJf "$tarball" -C "$WORK/$arch" "$name/bin/node"
    binary="$WORK/$arch/$name/bin/node"
    if [[ "$(lipo -archs "$binary")" != "$arch" ]]; then
        echo "ERROR: $name/bin/node is $(lipo -archs "$binary"), expected $arch" >&2
        exit 1
    fi
    THIN+=("$binary")
done

mkdir -p "$(dirname "$OUTPUT")"
rm -f "$OUTPUT"
if [[ ${#THIN[@]} -eq 1 ]]; then
    cp "${THIN[0]}" "$OUTPUT"
else
    lipo -create "${THIN[@]}" -output "$OUTPUT"
fi
chmod 755 "$OUTPUT"
echo "    Wrote $OUTPUT ($(lipo -archs "$OUTPUT"), $(du -h "$OUTPUT" | awk '{ print $1 }'))"
