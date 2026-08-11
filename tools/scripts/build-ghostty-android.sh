#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
GHOSTTY_DIR="$REPO_DIR/shared/third_party/ghostty"
BRIDGE_DIR="$REPO_DIR/apps/android/core/bridge"
JNI_DIR="$BRIDGE_DIR/src/main/jniLibs"
INCLUDE_DIR="$BRIDGE_DIR/src/main/cpp/include"
STAGING_DIR="${GHOSTTY_ANDROID_BUILD_DIR:-$REPO_DIR/apps/android/build/ghostty}"
ANDROID_ABIS="${ANDROID_ABIS:-arm64-v8a x86_64}"
HOST_DEVELOPER_DIR="${GHOSTTY_HOST_DEVELOPER_DIR:-}"
HOST_SDKROOT="${GHOSTTY_HOST_SDKROOT:-}"

if [ ! -f "$GHOSTTY_DIR/build.zig" ]; then
    echo "error: Ghostty submodule is missing; run git submodule update --init --recursive shared/third_party/ghostty" >&2
    exit 1
fi

# Apply Litter's mobile-embed patches if not already applied. Idempotent;
# safe to call on every build. Required when this script is invoked
# directly (CI, build-android-rust.sh fallback) without going through the
# Makefile's STAMP_SYNC_GHOSTTY dep chain.
"$REPO_DIR/apps/ios/scripts/sync-ghostty.sh" --preserve-current

ZIG_BIN="$("$REPO_DIR/tools/scripts/resolve-ghostty-zig.sh")"

if ! grep -q 'ghostty_surface_write' "$GHOSTTY_DIR/include/ghostty.h"; then
    echo "error: Ghostty header shape changed; expected external PTY ghostty_surface_write in include/ghostty.h" >&2
    exit 1
fi

if ! grep -q 'external_pty_write' "$GHOSTTY_DIR/include/ghostty.h"; then
    echo "error: Ghostty header shape changed; expected external_pty_write callback in include/ghostty.h" >&2
    exit 1
fi

if ! grep -q 'GHOSTTY_PLATFORM_ANDROID' "$GHOSTTY_DIR/include/ghostty.h"; then
    cat >&2 <<'EOF'
error: vendored Ghostty does not expose an Android platform surface yet.

The external-PTY API is present, but the current Ghostty embedding header has
macOS/iOS platform structs only. Add the planned ghostty_platform_android_s /
GHOSTTY_PLATFORM_ANDROID patch before building Android renderer artifacts.
EOF
    exit 2
fi

mkdir -p "$INCLUDE_DIR" "$STAGING_DIR"
cp "$GHOSTTY_DIR/include/ghostty.h" "$INCLUDE_DIR/ghostty.h"

ZIG_CACHE_DIR="${GHOSTTY_ANDROID_ZIG_CACHE_DIR:-$STAGING_DIR/zig-cache}"
rm -rf "$ZIG_CACHE_DIR"
mkdir -p "$ZIG_CACHE_DIR/global" "$ZIG_CACHE_DIR/local"

target_for_abi() {
    case "$1" in
        arm64-v8a) echo "aarch64-linux-android.26" ;;
        x86_64) echo "x86_64-linux-android.26" ;;
        *)
            echo "error: unsupported Android ABI: $1" >&2
            exit 1
            ;;
    esac
}

if [ "$(uname -s)" = "Darwin" ]; then
    # Zig 0.15.2 cannot link its macOS build runner against the Xcode 26.4
    # SDK's arm64e-only libSystem.tbd. The CLT SDK still advertises arm64 and
    # is sufficient for the host-side build runner used by this Android build.
    if [ -z "$HOST_DEVELOPER_DIR" ] && [ -d /Library/Developer/CommandLineTools ]; then
        HOST_DEVELOPER_DIR=/Library/Developer/CommandLineTools
    fi
    if [ -z "$HOST_SDKROOT" ] && [ -n "$HOST_DEVELOPER_DIR" ] && [ -d "$HOST_DEVELOPER_DIR/SDKs/MacOSX.sdk" ]; then
        HOST_SDKROOT="$HOST_DEVELOPER_DIR/SDKs/MacOSX.sdk"
    fi
fi

for abi in $ANDROID_ABIS; do
    target="$(target_for_abi "$abi")"
    prefix="$STAGING_DIR/$abi"
    env_args=()
    if [ -n "$HOST_DEVELOPER_DIR" ]; then
        env_args+=(DEVELOPER_DIR="$HOST_DEVELOPER_DIR")
    fi
    if [ -n "$HOST_SDKROOT" ]; then
        env_args+=(SDKROOT="$HOST_SDKROOT")
    fi
    env_args+=(
        ZIG_GLOBAL_CACHE_DIR="$ZIG_CACHE_DIR/global"
        ZIG_LOCAL_CACHE_DIR="$ZIG_CACHE_DIR/local"
    )

    echo "==> Building Ghostty Android renderer for $abi ($target)..."
    (
        cd "$GHOSTTY_DIR"
        env "${env_args[@]}" "$ZIG_BIN" build \
            -Dapp-runtime=none \
            -Drenderer=opengl \
            -Dfont-backend=freetype \
            -Demit-exe=false \
            -Demit-lib-vt=false \
            -Demit-xcframework=false \
            -Demit-docs=false \
            -Demit-terminfo=false \
            -Demit-termcap=false \
            -Demit-themes=false \
            -Demit-webdata=false \
            -Di18n=false \
            -Dsentry=false \
            -Dtarget="$target" \
            -Doptimize=ReleaseFast \
            --prefix "$prefix"
    )

    lib="$(find "$prefix" -type f \( -name 'ghostty-internal.so' -o -name 'libghostty*.so' \) | head -n 1)"
    if [ -z "$lib" ]; then
        echo "error: Ghostty Android build for $abi completed but no shared library was produced under $prefix" >&2
        exit 1
    fi

    mkdir -p "$JNI_DIR/$abi"
    cp "$lib" "$JNI_DIR/$abi/libghostty.so"
    if ! file "$JNI_DIR/$abi/libghostty.so" | grep -q 'ELF .* shared object'; then
        echo "error: installed Ghostty artifact for $abi is not an ELF shared object: $JNI_DIR/$abi/libghostty.so" >&2
        file "$JNI_DIR/$abi/libghostty.so" >&2
        exit 1
    fi
done

echo "==> Ghostty Android artifacts installed under $JNI_DIR and $INCLUDE_DIR"
