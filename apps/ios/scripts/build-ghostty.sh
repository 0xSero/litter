#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$IOS_DIR/../.." && pwd)"
GHOSTTY_DIR="$REPO_DIR/shared/third_party/ghostty"
GENERATED_DIR="$IOS_DIR/GeneratedRust"
STAGING_DIR="${GHOSTTY_BUILD_DIR:-$GENERATED_DIR/ghostty-build}"
XCODE_DEVELOPER_DIR="${GHOSTTY_XCODE_DEVELOPER_DIR:-$(xcode-select -p)}"
CLT_DEVELOPER_DIR="${GHOSTTY_CLT_DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"

if [ ! -f "$GHOSTTY_DIR/build.zig" ]; then
    echo "error: Ghostty submodule is missing; run git submodule update --init --recursive shared/third_party/ghostty" >&2
    exit 1
fi

ZIG_BIN="$("$REPO_DIR/tools/scripts/resolve-ghostty-zig.sh")"

# Apply Litter's mobile-embed patches if not already applied. Idempotent;
# safe to call on every build. Required when this script is invoked
# directly (CI, build-rust.sh fallback) without going through the
# Makefile's STAMP_SYNC_GHOSTTY dep chain.
"$REPO_DIR/apps/ios/scripts/sync-ghostty.sh" --preserve-current

if ! grep -q 'ghostty_surface_write' "$GHOSTTY_DIR/include/ghostty.h"; then
    echo "error: Ghostty header shape changed; expected external PTY ghostty_surface_write in include/ghostty.h" >&2
    exit 1
fi

if ! grep -q 'external_pty_write' "$GHOSTTY_DIR/include/ghostty.h"; then
    echo "error: Ghostty header shape changed; expected external_pty_write callback in include/ghostty.h" >&2
    exit 1
fi

if ! grep -q 'GHOSTTY_PLATFORM_IOS' "$GHOSTTY_DIR/include/ghostty.h"; then
    echo "error: vendored Ghostty does not expose the iOS platform surface" >&2
    exit 1
fi

ZIG_CACHE_DIR="${GHOSTTY_ZIG_CACHE_DIR:-$STAGING_DIR/zig-cache}"
MACOS_SDK_SHIM_DIR="$ZIG_CACHE_DIR/macos-sdk-shim/MacOSX.sdk"

mkdir -p "$GENERATED_DIR/Headers" "$GENERATED_DIR/ios-device" "$GENERATED_DIR/ios-sim" "$GENERATED_DIR/ios-macabi" "$STAGING_DIR/bin"
rm -rf "$ZIG_CACHE_DIR"
mkdir -p "$ZIG_CACHE_DIR/global" "$ZIG_CACHE_DIR/local"

if [ ! -d "$XCODE_DEVELOPER_DIR/Platforms/iPhoneOS.platform" ]; then
    echo "error: Xcode developer dir does not contain iPhoneOS SDKs: $XCODE_DEVELOPER_DIR" >&2
    exit 1
fi

patch_tbd_for_arm64() {
    local source="$1"
    local dest="$2"

    mkdir -p "$(dirname "$dest")"
    sed \
        -e 's/arm64e-macos, arm64e-maccatalyst/arm64-macos, arm64-maccatalyst, arm64e-macos, arm64e-maccatalyst/g' \
        -e 's/\[ arm64e-macos/[ arm64-macos, arm64e-macos/g' \
        "$source" > "$dest"
}

copy_macos_sdk_libs_for_zig() {
    local source_dir="$1"
    local dest_dir="$2"
    local entry
    local dest

    mkdir -p "$dest_dir"
    find "$source_dir" -mindepth 1 -maxdepth 1 | while IFS= read -r entry; do
        dest="$dest_dir/$(basename "$entry")"
        if [ -d "$entry" ] && [ ! -L "$entry" ]; then
            copy_macos_sdk_libs_for_zig "$entry" "$dest"
        elif [[ "$entry" == *.tbd ]]; then
            patch_tbd_for_arm64 "$entry" "$dest"
        else
            ln -s "$entry" "$dest"
        fi
    done
}

prepare_macos_sdk_for_zig() {
    local xcode_sdk
    local source_sdk
    local entry
    local dest

    if [ -d "$CLT_DEVELOPER_DIR/SDKs/MacOSX.sdk" ] &&
        head -n 8 "$CLT_DEVELOPER_DIR/SDKs/MacOSX.sdk/usr/lib/libSystem.tbd" | grep -q 'arm64-macos'; then
        printf '%s\n' "$CLT_DEVELOPER_DIR/SDKs/MacOSX.sdk"
        return
    fi

    xcode_sdk="$(env DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" /usr/bin/xcrun --sdk macosx --show-sdk-path)"

    echo "==> Preparing Zig host macOS SDK shim from $xcode_sdk..." >&2
    source_sdk="$xcode_sdk"
    rm -rf "$MACOS_SDK_SHIM_DIR"
    mkdir -p "$MACOS_SDK_SHIM_DIR/usr"

    find "$source_sdk" -mindepth 1 -maxdepth 1 | while IFS= read -r entry; do
        case "$(basename "$entry")" in
            usr) ;;
            *)
                ln -s "$entry" "$MACOS_SDK_SHIM_DIR/$(basename "$entry")"
                ;;
        esac
    done

    # The host linker still needs the SDK framework tree for macabi and other
    # Darwin-host helper builds, so make the top-level SDK entries explicit.
    for entry in Entitlements.plist SDKSettings.json SDKSettings.plist System; do
        if [ -e "$source_sdk/$entry" ] && [ ! -e "$MACOS_SDK_SHIM_DIR/$entry" ]; then
            ln -s "$source_sdk/$entry" "$MACOS_SDK_SHIM_DIR/$entry"
        fi
    done

    find "$source_sdk/usr" -mindepth 1 -maxdepth 1 | while IFS= read -r entry; do
        dest="$MACOS_SDK_SHIM_DIR/usr/$(basename "$entry")"
        case "$(basename "$entry")" in
            lib)
                copy_macos_sdk_libs_for_zig "$entry" "$dest"
                ;;
            *)
                ln -s "$entry" "$dest"
                ;;
        esac
    done

    printf '%s\n' "$MACOS_SDK_SHIM_DIR"
}

MACOS_SDK_FOR_ZIG="$(prepare_macos_sdk_for_zig)"

# Zig 0.15.2 can fail to link its macOS build runner against Xcode 26's
# arm64e-only macOS SDK stubs. Keep iOS SDK lookups on Xcode, but route host
# macOS SDK lookup through CLT when available, otherwise through the shim above.
cat > "$STAGING_DIR/bin/xcrun" <<EOF
#!/usr/bin/env bash
sdk=""
prev=""
for arg in "\$@"; do
    if [ "\$prev" = "--sdk" ]; then
        sdk="\$arg"
        break
    fi
    prev="\$arg"
done

case "\$sdk" in
    macosx)
        for arg in "\$@"; do
            if [ "\$arg" = "--show-sdk-path" ]; then
                printf '%s\n' "$MACOS_SDK_FOR_ZIG"
                exit 0
            fi
        done
        if [ -d "$CLT_DEVELOPER_DIR/SDKs/MacOSX.sdk" ]; then
            exec env DEVELOPER_DIR="$CLT_DEVELOPER_DIR" /usr/bin/xcrun "\$@"
        fi
        ;;
esac

exec env DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" /usr/bin/xcrun "\$@"
EOF
chmod +x "$STAGING_DIR/bin/xcrun"

build_slice() {
    local name="$1"
    local target="$2"
    local cpu="$3"
    local output="$4"
    local prefix="$STAGING_DIR/$name"
    local zig_args

    rm -rf "$prefix"
    mkdir -p "$prefix"

    echo "==> Building Ghostty $name static library..."
    (
        cd "$GHOSTTY_DIR"
        zig_args=("$ZIG_BIN" build \
            -Dlitter-ios-static=true \
            -Dapp-runtime=none \
            -Drenderer=metal \
            -Dfont-backend=coretext \
            -Demit-exe=false \
            -Demit-lib-vt=false \
            -Demit-xcframework=false \
            -Demit-macos-app=false \
            -Demit-docs=false \
            -Demit-terminfo=false \
            -Demit-termcap=false \
            -Demit-themes=false \
            -Demit-webdata=false \
            -Di18n=false \
            -Dsentry=false \
            -Dtarget="$target")
        if [ -n "$cpu" ]; then
            zig_args+=(-Dcpu="$cpu")
        fi
        zig_args+=(\
            -Doptimize=ReleaseFast \
            --prefix "$prefix")
        env \
            PATH="$STAGING_DIR/bin:$PATH" \
            DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" \
            ZIG_GLOBAL_CACHE_DIR="$ZIG_CACHE_DIR/global" \
            ZIG_LOCAL_CACHE_DIR="$ZIG_CACHE_DIR/local" \
            "${zig_args[@]}"
    )

    if [ ! -f "$prefix/lib/ghostty-internal.a" ]; then
        echo "error: Ghostty $name build completed but $prefix/lib/ghostty-internal.a was not produced" >&2
        exit 1
    fi

    cp "$prefix/lib/ghostty-internal.a" "$output"
}

echo "==> Building Ghostty iOS static libraries from $(git -C "$GHOSTTY_DIR" rev-parse --short HEAD)..."
build_slice "ios-device" "aarch64-ios.18.0" "" "$GENERATED_DIR/ios-device/libghostty.a"
build_slice "ios-sim" "aarch64-ios.18.0-simulator" "apple_a17" "$GENERATED_DIR/ios-sim/libghostty.a"
build_slice "ios-macabi-arm64" "aarch64-ios.18.0-macabi" "apple_m1" "$GENERATED_DIR/ios-macabi/libghostty.a"

cp "$GHOSTTY_DIR/include/ghostty.h" "$GENERATED_DIR/Headers/ghostty.h"

echo "==> Ghostty iOS artifacts installed:"
echo "    $GENERATED_DIR/Headers/ghostty.h"
echo "    $GENERATED_DIR/ios-device/libghostty.a"
echo "    $GENERATED_DIR/ios-sim/libghostty.a"
echo "    $GENERATED_DIR/ios-macabi/libghostty.a"
