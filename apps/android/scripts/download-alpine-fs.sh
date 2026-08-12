#!/usr/bin/env bash
# Download the pinned Alpine fakefs rootfs tarball for Android proot.
#
# Usage:
#   ALPINE_FS_VERSION=v0.1.1 ./apps/android/scripts/download-alpine-fs.sh
#
# Outputs:
#   apps/android/app/src/main/assets/alpine-fs.tgz

set -euo pipefail

VERSION="${ALPINE_FS_VERSION:-}"
if [[ -z "$VERSION" ]]; then
    echo "error: ALPINE_FS_VERSION must be set (e.g. v0.1.1)" >&2
    exit 1
fi

REPO="dnakov/litter-ish"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ANDROID_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ASSETS_DIR="$ANDROID_DIR/app/src/main/assets"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

BASE_URL="https://github.com/$REPO/releases/download/$VERSION"
FAKEFS_TGZ="fs.tar.gz"
ASSET_NAME="alpine-fs.tgz"
SUMS="SHA256SUMS"

fetch() {
    local name="$1"
    echo "==> Downloading $name"
    if command -v gh >/dev/null 2>&1; then
        gh release download "$VERSION" \
            --repo "$REPO" \
            --pattern "$name" \
            --dir "$TMP_DIR"
        return
    fi

    # GitHub release assets redirect to Azure Blob Storage, which can
    # intermittently close HTTP/2 streams on longer build runs. Retry every
    # transient transport failure over HTTP/1.1 when the GitHub CLI is not
    # available, so an otherwise-complete Android build is not discarded by a
    # flaky asset fetch.
    curl -fsSL \
        --http1.1 \
        --retry 5 \
        --retry-all-errors \
        --retry-delay 1 \
        -o "$TMP_DIR/$name" \
        "$BASE_URL/$name"
}

fetch "$FAKEFS_TGZ"
fetch "$SUMS"

echo "==> Verifying checksum for $FAKEFS_TGZ"
( cd "$TMP_DIR" && grep " $FAKEFS_TGZ\$" "$SUMS" | shasum -a 256 -c - )

mkdir -p "$ASSETS_DIR"
rm -f "$ASSETS_DIR/alpine-fs.tar.gz"
cp "$TMP_DIR/$FAKEFS_TGZ" "$ASSETS_DIR/$ASSET_NAME"
printf 'alpine-fs=%s\n' "$VERSION" > "$ASSETS_DIR/alpine-fs.version"

echo
echo "Android alpine-fs $VERSION installed:"
du -sh "$ASSETS_DIR/$ASSET_NAME"
