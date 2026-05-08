#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$IOS_DIR/../.." && pwd)"
source "$REPO_DIR/tools/scripts/load-sccache-aws-creds.sh"
RUST_BRIDGE_DIR="$REPO_DIR/shared/rust-bridge"
CARGO_TARGET_DIR_EFFECTIVE="${CARGO_TARGET_DIR:-$RUST_BRIDGE_DIR/target}"
FRAMEWORKS_DIR="$IOS_DIR/Frameworks"
GENERATED_SWIFT_DIR="$RUST_BRIDGE_DIR/generated/swift"
UNIFFI_OUT="$IOS_DIR/Sources/Litter/Bridge/UniFFICodexClient.generated.swift"
GENERATED_RUST_DIR="$IOS_DIR/GeneratedRust"
GENERATED_HEADERS_DIR="$GENERATED_RUST_DIR/Headers"
GENERATED_DEVICE_DIR="$GENERATED_RUST_DIR/ios-device"
GENERATED_SIM_DIR="$GENERATED_RUST_DIR/ios-sim"
GENERATED_MACABI_DIR="$GENERATED_RUST_DIR/ios-macabi"
BINDINGS_HASH_FILE="$GENERATED_RUST_DIR/.swift-bindings.hash"
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-18.0}"
MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
SUBMODULE_DIR="$REPO_DIR/shared/third_party/codex"
IOS_CLANGXX_WRAPPER="$SCRIPT_DIR/ios-clangxx-wrapper.sh"
PATCH_FILES=(
  "$REPO_DIR/patches/codex/ios-exec-hook.patch"
  "$REPO_DIR/patches/codex/client-controlled-handoff.patch"
  "$REPO_DIR/patches/codex/mobile-code-mode-stub.patch"
  "$REPO_DIR/patches/codex/thread-read-permissions.patch"
)

SYNC_MODE="--preserve-current"
DEVICE_ONLY=0
FAST_DEVICE=0
SIM_ONLY=0
FAST_SIM=0
MACABI_ONLY=0
FAST_MACABI=0
FORCE_BINDINGS=0
SKIP_BINDINGS=0
CARGO_FEATURES=""
PROFILE="release"
CARGO_PROFILE_FLAG="--release"
IOS_RUST_PROFILE="${IOS_RUST_PROFILE:-release}"

HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  arm64|aarch64) MACABI_HOST_TARGET="aarch64-apple-ios-macabi" ;;
  x86_64) MACABI_HOST_TARGET="x86_64-apple-ios-macabi" ;;
  *) MACABI_HOST_TARGET="" ;;
esac

if [ "$IOS_RUST_PROFILE" != "release" ]; then
  PROFILE="$IOS_RUST_PROFILE"
  CARGO_PROFILE_FLAG="--profile $IOS_RUST_PROFILE"
fi

for arg in "$@"; do
  case "$arg" in
    --preserve-current|--recorded-gitlink)
      SYNC_MODE="$arg"
      ;;
    --device-only)
      DEVICE_ONLY=1
      ;;
    --fast-device)
      FAST_DEVICE=1
      DEVICE_ONLY=1
      PROFILE="ios-dev"
      CARGO_PROFILE_FLAG="--profile ios-dev"
      ;;
    --fast-sim)
      FAST_SIM=1
      SIM_ONLY=1
      PROFILE="ios-dev"
      CARGO_PROFILE_FLAG="--profile ios-dev"
      ;;
    --macabi-only)
      # Build only the Mac Catalyst (macabi) arches. Skips xcframework
      # packaging — the LitterMac target links the raw macabi staticlib
      # directly via LIBRARY_SEARCH_PATHS[sdk=macosx*].
      MACABI_ONLY=1
      ;;
    --fast-macabi)
      # Fast Catalyst dev lane: build only the host arch (arm64 on
      # Apple Silicon, x86_64 on Intel) using the ios-dev profile (no
      # LTO, codegen-units=256, line-table debuginfo). Xcode Debug
      # Catalyst builds default to ONLY_ACTIVE_ARCH=YES, so a host-only
      # staticlib is sufficient. Skips xcframework + lipo.
      FAST_MACABI=1
      MACABI_ONLY=1
      PROFILE="ios-dev"
      CARGO_PROFILE_FLAG="--profile ios-dev"
      if [ -z "$MACABI_HOST_TARGET" ]; then
        echo "ERROR: --fast-macabi unsupported on host arch $HOST_ARCH" >&2
        exit 1
      fi
      ;;
    --force-bindings)
      FORCE_BINDINGS=1
      ;;
    --skip-bindings)
      SKIP_BINDINGS=1
      ;;
    --rpc-trace)
      CARGO_FEATURES="--features rpc-trace"
      ;;
    *)
      echo "usage: $(basename "$0") [--preserve-current|--recorded-gitlink] [--device-only] [--fast-device] [--fast-sim] [--macabi-only] [--fast-macabi] [--force-bindings] [--skip-bindings] [--rpc-trace]" >&2
      exit 1
      ;;
  esac
done

PATCHES_WERE_APPLIED=()
for PATCH_FILE in "${PATCH_FILES[@]}"; do
  if git -C "$SUBMODULE_DIR" apply --reverse --check "$PATCH_FILE" >/dev/null 2>&1; then
    PATCHES_WERE_APPLIED+=("$PATCH_FILE")
  fi
done

cleanup_patch() {
  for PATCH_FILE in "${PATCH_FILES[@]}"; do
    local was_pre_applied=0
    for pre in "${PATCHES_WERE_APPLIED[@]+"${PATCHES_WERE_APPLIED[@]}"}"; do
      if [ "$pre" = "$PATCH_FILE" ]; then
        was_pre_applied=1
        break
      fi
    done
    if [ "$was_pre_applied" -eq 0 ] && git -C "$SUBMODULE_DIR" apply --reverse --check "$PATCH_FILE" >/dev/null 2>&1; then
      echo "==> Reverting $(basename "$PATCH_FILE")..."
      git -C "$SUBMODULE_DIR" apply --reverse "$PATCH_FILE"
    fi
  done
}

trap cleanup_patch EXIT

mkdir -p "$FRAMEWORKS_DIR" "$GENERATED_HEADERS_DIR" "$GENERATED_DEVICE_DIR" "$GENERATED_SIM_DIR" "$GENERATED_MACABI_DIR"

if [ -z "${RUSTC_WRAPPER:-}" ] && command -v sccache >/dev/null 2>&1; then
  export RUSTC_WRAPPER="$(command -v sccache)"
fi

ensure_host_llvm_on_path() {
  local candidate
  local llvm_candidates=(
    "/opt/homebrew/opt/llvm/bin"
    "/usr/local/opt/llvm/bin"
    "/opt/local/bin"
  )

  if [ -n "${ANDROID_NDK_HOME:-}" ]; then
    for candidate in "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/bin; do
      llvm_candidates+=("$candidate")
    done
  fi

  if [ -n "${ANDROID_NDK_ROOT:-}" ]; then
    for candidate in "$ANDROID_NDK_ROOT"/toolchains/llvm/prebuilt/*/bin; do
      llvm_candidates+=("$candidate")
    done
  fi

  for candidate in /opt/homebrew/share/android-commandlinetools/ndk/*/toolchains/llvm/prebuilt/*/bin; do
    llvm_candidates+=("$candidate")
  done

  for candidate in "${llvm_candidates[@]}"; do
    if [ -x "$candidate/clang" ] && [ -x "$candidate/ld.lld" ]; then
      case ":$PATH:" in
        *":$candidate:"*) ;;
        *) export PATH="$candidate:$PATH" ;;
      esac
      return
    fi
  done
}

ensure_host_llvm_on_path

export CXX_aarch64_apple_ios="$IOS_CLANGXX_WRAPPER"
export CXX_aarch64_apple_ios_sim="$IOS_CLANGXX_WRAPPER"
export CXX_aarch64_apple_ios_macabi="$IOS_CLANGXX_WRAPPER"
export CXX_x86_64_apple_ios_macabi="$IOS_CLANGXX_WRAPPER"
export IPHONEOS_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET"
export MACOSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET"

# bindgen 0.70 maps `aarch64-apple-ios-sim` -> `arm64-apple-ios-sim`, which
# clang rejects ("version 'sim' in target triple ... is invalid"). The correct
# clang triple uses the `-simulator` environment suffix. Override per-target so
# bindgen-driven build scripts (e.g. ish-embed-host) point at the iPhoneSimulator
# SDK when cross-compiling for the simulator.
IPHONESIM_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null || true)"
if [ -n "$IPHONESIM_SDK" ]; then
  export BINDGEN_EXTRA_CLANG_ARGS_aarch64_apple_ios_sim="--target=arm64-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator -isysroot ${IPHONESIM_SDK}"
fi

bindings_inputs() {
  cat <<EOF
$RUST_BRIDGE_DIR/codex-mobile-client/src/lib.rs
$RUST_BRIDGE_DIR/codex-mobile-client/src/conversation_uniffi.rs
$RUST_BRIDGE_DIR/codex-mobile-client/src/discovery_uniffi.rs
$RUST_BRIDGE_DIR/codex-mobile-client/src/uniffi_shared.rs
$RUST_BRIDGE_DIR/codex-mobile-client/Cargo.toml
$RUST_BRIDGE_DIR/Cargo.lock
$RUST_BRIDGE_DIR/../third_party/codex/codex-rs/app-server-protocol/src/protocol/common.rs
$RUST_BRIDGE_DIR/../third_party/codex/codex-rs/app-server-protocol/src/protocol/v1.rs
$RUST_BRIDGE_DIR/../third_party/codex/codex-rs/app-server-protocol/src/protocol/v2.rs
$RUST_BRIDGE_DIR/../third_party/codex/codex-rs/protocol/src/account.rs
$RUST_BRIDGE_DIR/../third_party/codex/codex-rs/protocol/src/config_types.rs
$RUST_BRIDGE_DIR/../third_party/codex/codex-rs/protocol/src/models.rs
$RUST_BRIDGE_DIR/../third_party/codex/codex-rs/protocol/src/openai_models.rs
$RUST_BRIDGE_DIR/../third_party/codex/codex-rs/protocol/src/parse_command.rs
$RUST_BRIDGE_DIR/../third_party/codex/codex-rs/protocol/src/protocol.rs
EOF
  find "$RUST_BRIDGE_DIR/codex-mobile-client/src" -type f -name '*.rs' | sort
}

compute_bindings_hash() {
  local file
  {
    while IFS= read -r file; do
      [ -f "$file" ] || continue
      shasum -a 256 "$file"
    done < <(bindings_inputs | sort)
  } | shasum -a 256 | awk '{print $1}'
}

sync_generated_headers() {
  cp "$GENERATED_SWIFT_DIR/codex_mobile_clientFFI.h" "$GENERATED_HEADERS_DIR/codex_mobile_clientFFI.h"
  cp "$GENERATED_SWIFT_DIR/codex_mobile_clientFFI.modulemap" "$GENERATED_HEADERS_DIR/codex_mobile_clientFFI.modulemap"
  cp "$GENERATED_SWIFT_DIR/module.modulemap" "$GENERATED_HEADERS_DIR/module.modulemap"
}

maybe_generate_swift_bindings() {
  local current_hash existing_hash
  if [ "$SKIP_BINDINGS" -eq 1 ]; then
    echo "==> Skipping UniFFI Swift bindings (--skip-bindings)"
    return
  fi

  current_hash="$(compute_bindings_hash)"
  existing_hash=""
  if [ -f "$BINDINGS_HASH_FILE" ]; then
    existing_hash="$(cat "$BINDINGS_HASH_FILE")"
  fi

  if [ "$FORCE_BINDINGS" -eq 0 ] &&
    [ "$current_hash" = "$existing_hash" ] &&
    [ -f "$GENERATED_SWIFT_DIR/codex_mobile_client.swift" ] &&
    [ -f "$GENERATED_SWIFT_DIR/codex_mobile_clientFFI.h" ] &&
    [ -f "$UNIFFI_OUT" ]; then
    echo "==> Swift bindings unchanged; reusing generated output"
    sync_generated_headers
    return
  fi

  echo "==> Regenerating UniFFI Swift bindings -> $UNIFFI_OUT"
  cd "$RUST_BRIDGE_DIR"
  "$RUST_BRIDGE_DIR/generate-bindings.sh" --swift-only
  cp "$GENERATED_SWIFT_DIR/codex_mobile_client.swift" "$UNIFFI_OUT"
  sync_generated_headers
  printf '%s\n' "$current_hash" >"$BINDINGS_HASH_FILE"
}

copy_device_artifact() {
  cp "$CARGO_TARGET_DIR_EFFECTIVE/aarch64-apple-ios/$PROFILE/libcodex_mobile_client.a" \
    "$GENERATED_DEVICE_DIR/libcodex_mobile_client.a"
}

copy_sim_artifact() {
  local sim_lib="$1"
  cp "$sim_lib" "$GENERATED_SIM_DIR/libcodex_mobile_client.a"
}

copy_macabi_artifact() {
  local arm64_lib="$CARGO_TARGET_DIR_EFFECTIVE/aarch64-apple-ios-macabi/$PROFILE/libcodex_mobile_client.a"
  local x86_64_lib="$CARGO_TARGET_DIR_EFFECTIVE/x86_64-apple-ios-macabi/$PROFILE/libcodex_mobile_client.a"
  lipo -create "$arm64_lib" "$x86_64_lib" \
    -output "$GENERATED_MACABI_DIR/libcodex_mobile_client.a"
}

echo "==> Preparing codex submodule..."
"$SCRIPT_DIR/sync-codex.sh" "$SYNC_MODE"

maybe_generate_swift_bindings

echo "==> Installing iOS targets..."
if [ "$DEVICE_ONLY" -eq 1 ]; then
  rustup target add aarch64-apple-ios
elif [ "$SIM_ONLY" -eq 1 ]; then
  rustup target add aarch64-apple-ios-sim
elif [ "$MACABI_ONLY" -eq 1 ]; then
  if [ "$FAST_MACABI" -eq 1 ]; then
    rustup target add "$MACABI_HOST_TARGET"
  else
    rustup target add aarch64-apple-ios-macabi x86_64-apple-ios-macabi
  fi
else
  rustup target add aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-ios-macabi x86_64-apple-ios-macabi
fi
rustup target add i686-unknown-linux-musl

if [ "$DEVICE_ONLY" -eq 1 ]; then
  echo "==> Building codex-mobile-client for aarch64-apple-ios ($PROFILE)..."
  cargo rustc --manifest-path "$RUST_BRIDGE_DIR/Cargo.toml" -p codex-mobile-client $CARGO_PROFILE_FLAG --target aarch64-apple-ios --crate-type staticlib $CARGO_FEATURES
  copy_device_artifact
elif [ "$SIM_ONLY" -eq 1 ]; then
  echo "==> Building codex-mobile-client for aarch64-apple-ios-sim ($PROFILE)..."
  cargo rustc --manifest-path "$RUST_BRIDGE_DIR/Cargo.toml" -p codex-mobile-client $CARGO_PROFILE_FLAG --target aarch64-apple-ios-sim --crate-type staticlib $CARGO_FEATURES
  copy_sim_artifact "$CARGO_TARGET_DIR_EFFECTIVE/aarch64-apple-ios-sim/$PROFILE/libcodex_mobile_client.a"
elif [ "$MACABI_ONLY" -eq 1 ]; then
  if [ "$FAST_MACABI" -eq 1 ]; then
    echo "==> Building codex-mobile-client for $MACABI_HOST_TARGET ($PROFILE)..."
    cargo rustc --manifest-path "$RUST_BRIDGE_DIR/Cargo.toml" -p codex-mobile-client $CARGO_PROFILE_FLAG --target "$MACABI_HOST_TARGET" --crate-type staticlib $CARGO_FEATURES
    cp "$CARGO_TARGET_DIR_EFFECTIVE/$MACABI_HOST_TARGET/$PROFILE/libcodex_mobile_client.a" \
      "$GENERATED_MACABI_DIR/libcodex_mobile_client.a"
  else
    echo "==> Building codex-mobile-client for Mac Catalyst macabi targets ($PROFILE) in parallel..."

    build_macabi_arm64() {
      cargo rustc --manifest-path "$RUST_BRIDGE_DIR/Cargo.toml" -p codex-mobile-client $CARGO_PROFILE_FLAG --target aarch64-apple-ios-macabi --crate-type staticlib $CARGO_FEATURES
    }

    build_macabi_x86_64() {
      cargo rustc --manifest-path "$RUST_BRIDGE_DIR/Cargo.toml" -p codex-mobile-client $CARGO_PROFILE_FLAG --target x86_64-apple-ios-macabi --crate-type staticlib $CARGO_FEATURES
    }

    build_macabi_arm64 &
    MACABI_ARM64_PID=$!
    build_macabi_x86_64 &
    MACABI_X86_64_PID=$!

    FAILED=0
    if ! wait "$MACABI_ARM64_PID"; then
      echo "ERROR: Catalyst build (aarch64-apple-ios-macabi) failed" >&2
      FAILED=1
    fi
    if ! wait "$MACABI_X86_64_PID"; then
      echo "ERROR: Catalyst build (x86_64-apple-ios-macabi) failed" >&2
      FAILED=1
    fi
    [ "$FAILED" -eq 0 ] || exit 1

    copy_macabi_artifact
  fi
else
  # Build device and simulator targets in parallel
  echo "==> Building codex-mobile-client for device, simulator, and Catalyst macabi targets ($PROFILE) in parallel..."

  build_device() {
    cargo rustc --manifest-path "$RUST_BRIDGE_DIR/Cargo.toml" -p codex-mobile-client $CARGO_PROFILE_FLAG --target aarch64-apple-ios --crate-type staticlib $CARGO_FEATURES
  }

  build_sim() {
    cargo rustc --manifest-path "$RUST_BRIDGE_DIR/Cargo.toml" -p codex-mobile-client $CARGO_PROFILE_FLAG --target aarch64-apple-ios-sim --crate-type staticlib $CARGO_FEATURES
  }

  build_macabi_arm64() {
    cargo rustc --manifest-path "$RUST_BRIDGE_DIR/Cargo.toml" -p codex-mobile-client $CARGO_PROFILE_FLAG --target aarch64-apple-ios-macabi --crate-type staticlib $CARGO_FEATURES
  }

  build_macabi_x86_64() {
    cargo rustc --manifest-path "$RUST_BRIDGE_DIR/Cargo.toml" -p codex-mobile-client $CARGO_PROFILE_FLAG --target x86_64-apple-ios-macabi --crate-type staticlib $CARGO_FEATURES
  }

  build_device &
  DEVICE_PID=$!
  build_sim &
  SIM_PID=$!
  build_macabi_arm64 &
  MACABI_ARM64_PID=$!
  build_macabi_x86_64 &
  MACABI_X86_64_PID=$!

  FAILED=0
  if ! wait "$DEVICE_PID"; then
    echo "ERROR: device build (aarch64-apple-ios) failed" >&2
    FAILED=1
  fi
  if ! wait "$SIM_PID"; then
    echo "ERROR: simulator build (aarch64-apple-ios-sim) failed" >&2
    FAILED=1
  fi
  if ! wait "$MACABI_ARM64_PID"; then
    echo "ERROR: Catalyst build (aarch64-apple-ios-macabi) failed" >&2
    FAILED=1
  fi
  if ! wait "$MACABI_X86_64_PID"; then
    echo "ERROR: Catalyst build (x86_64-apple-ios-macabi) failed" >&2
    FAILED=1
  fi
  [ "$FAILED" -eq 0 ] || exit 1

  copy_device_artifact
  copy_sim_artifact "$CARGO_TARGET_DIR_EFFECTIVE/aarch64-apple-ios-sim/$PROFILE/libcodex_mobile_client.a"
  copy_macabi_artifact
fi

if [ "$FAST_DEVICE" -eq 1 ]; then
  echo "==> Fast device build complete"
  echo "==> Device staticlib: $GENERATED_DEVICE_DIR/libcodex_mobile_client.a"
  echo "==> Headers: $GENERATED_HEADERS_DIR"
  echo "==> Swift bindings: $UNIFFI_OUT"
  exit 0
fi

if [ "$FAST_SIM" -eq 1 ]; then
  echo "==> Fast simulator build complete"
  echo "==> Simulator staticlib: $GENERATED_SIM_DIR/libcodex_mobile_client.a"
  echo "==> Headers: $GENERATED_HEADERS_DIR"
  echo "==> Swift bindings: $UNIFFI_OUT"
  exit 0
fi

if [ "$MACABI_ONLY" -eq 1 ]; then
  # LitterMac links the raw macabi staticlib via
  # LIBRARY_SEARCH_PATHS[sdk=macosx*] — no xcframework needed.
  if [ "$FAST_MACABI" -eq 1 ]; then
    echo "==> Fast Mac Catalyst build complete ($MACABI_HOST_TARGET, $PROFILE)"
  else
    echo "==> Mac Catalyst (macabi) build complete"
  fi
  echo "==> Macabi staticlib: $GENERATED_MACABI_DIR/libcodex_mobile_client.a"
  echo "==> Headers: $GENERATED_HEADERS_DIR"
  echo "==> Swift bindings: $UNIFFI_OUT"
  exit 0
fi

echo "==> Creating xcframework..."
rm -rf "$FRAMEWORKS_DIR/codex_bridge.xcframework" "$FRAMEWORKS_DIR/codex_mobile_client.xcframework"
if [ "$DEVICE_ONLY" -eq 1 ]; then
  xcodebuild -create-xcframework \
    -library "$GENERATED_DEVICE_DIR/libcodex_mobile_client.a" \
    -headers "$GENERATED_HEADERS_DIR" \
    -output "$FRAMEWORKS_DIR/codex_mobile_client.xcframework"
else
  xcodebuild -create-xcframework \
    -library "$GENERATED_DEVICE_DIR/libcodex_mobile_client.a" \
    -headers "$GENERATED_HEADERS_DIR" \
    -library "$GENERATED_SIM_DIR/libcodex_mobile_client.a" \
    -headers "$GENERATED_HEADERS_DIR" \
    -library "$GENERATED_MACABI_DIR/libcodex_mobile_client.a" \
    -headers "$GENERATED_HEADERS_DIR" \
    -output "$FRAMEWORKS_DIR/codex_mobile_client.xcframework"
fi

echo "==> Done: $FRAMEWORKS_DIR/codex_mobile_client.xcframework"
echo "==> Raw device staticlib: $GENERATED_DEVICE_DIR/libcodex_mobile_client.a"
if [ "$DEVICE_ONLY" -eq 0 ]; then
  echo "==> Raw simulator staticlib: $GENERATED_SIM_DIR/libcodex_mobile_client.a"
  echo "==> Raw Catalyst staticlib: $GENERATED_MACABI_DIR/libcodex_mobile_client.a"
fi
echo "==> Headers: $GENERATED_HEADERS_DIR"
echo "==> Swift bindings: $UNIFFI_OUT"
