#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE_DIR="$REPO_DIR/shared/rust-bridge"
OUT_DIR="$REPO_DIR/apps/android/core/bridge/src/main/jniLibs"
SYNC_SCRIPT="$REPO_DIR/apps/ios/scripts/sync-codex.sh"
DEFAULT_ANDROID_ABIS="arm64-v8a"
DEFAULT_ANDROID_RUST_PROFILE="android-dev"

if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo is required" >&2
  exit 1
fi

if ! command -v cargo-ndk >/dev/null 2>&1; then
  echo "error: cargo-ndk is required (install with: cargo install cargo-ndk)" >&2
  exit 1
fi

if [ -z "${ANDROID_NDK_HOME:-}" ] && [ -z "${ANDROID_NDK_ROOT:-}" ]; then
  echo "error: set ANDROID_NDK_HOME or ANDROID_NDK_ROOT" >&2
  exit 1
fi

if [ "${CARGO_INCREMENTAL:-}" != "1" ] && command -v sccache >/dev/null 2>&1; then
  export RUSTC_WRAPPER="$(command -v sccache)"
fi

# libghostty.so per-ABI must exist before the Android JNI bridge links
# (apps/android/core/bridge CMakeLists looks for it under jniLibs/$ABI/).
# Build it on demand if any requested ABI is missing — self-sufficient for
# CI workflows that invoke this script directly.
ABIS_FOR_GHOSTTY="${ANDROID_ABIS:-$DEFAULT_ANDROID_ABIS}"
NEED_GHOSTTY=0
for abi in ${ABIS_FOR_GHOSTTY//,/ }; do
  if [ ! -f "$OUT_DIR/$abi/libghostty.so" ]; then
    NEED_GHOSTTY=1
    break
  fi
done
if [ "$NEED_GHOSTTY" = 1 ]; then
  echo "==> libghostty.so missing for one or more ABIs; building (use 'make ghostty-android' for stamp caching)"
  ANDROID_ABIS="$ABIS_FOR_GHOSTTY" "$REPO_DIR/tools/scripts/build-ghostty-android.sh"
fi

echo "==> Preparing codex submodule..."
"$SYNC_SCRIPT" --preserve-current

"$REPO_DIR/tools/scripts/update-alleycat-main.sh" --shared

ABI_INPUT="${ANDROID_ABIS:-$DEFAULT_ANDROID_ABIS}"
ABI_INPUT="${ABI_INPUT//,/ }"
read -r -a REQUESTED_ABIS <<<"$ABI_INPUT"
RUST_PROFILE="${ANDROID_RUST_PROFILE:-$DEFAULT_ANDROID_RUST_PROFILE}"

if [ "${#REQUESTED_ABIS[@]}" -eq 0 ]; then
  REQUESTED_ABIS=("$DEFAULT_ANDROID_ABIS")
fi

declare -a ABI_ARGS=()
SELECTED_ABIS=""
SELECTED_RUST_TARGETS=""

for abi in "${REQUESTED_ABIS[@]}"; do
  case "$abi" in
    arm64-v8a|aarch64-linux-android)
      ABI_NAME="arm64-v8a"
      RUST_TARGET="aarch64-linux-android"
      ;;
    x86_64|x86-64|x86_64-linux-android)
      ABI_NAME="x86_64"
      RUST_TARGET="x86_64-linux-android"
      ;;
    *)
      echo "error: unsupported Android ABI '$abi' (supported: arm64-v8a, x86_64)" >&2
      exit 1
      ;;
  esac

  if [[ " $SELECTED_ABIS " != *" $ABI_NAME "* ]]; then
    ABI_ARGS+=(-t "$ABI_NAME")
    SELECTED_ABIS="$SELECTED_ABIS $ABI_NAME"
  fi

  if [[ " $SELECTED_RUST_TARGETS " != *" $RUST_TARGET "* ]]; then
    SELECTED_RUST_TARGETS="$SELECTED_RUST_TARGETS $RUST_TARGET"
  fi
done

read -r -a RUST_TARGETS <<<"${SELECTED_RUST_TARGETS# }"

echo "==> Selected Android ABIs: ${SELECTED_ABIS# }"
echo "==> Android Rust profile: $RUST_PROFILE"

echo "==> Installing Android Rust targets..."
rustup target add "${RUST_TARGETS[@]}"

mkdir -p "$OUT_DIR"

for abi_dir in arm64-v8a x86_64; do
  if [[ " $SELECTED_ABIS " != *" $abi_dir "* ]]; then
    rm -rf "$OUT_DIR/$abi_dir"
  fi
done

echo "==> Building codex_mobile_client Android shared libs..."
cd "$WORKSPACE_DIR"
cargo ndk "${ABI_ARGS[@]}" -o "$OUT_DIR" build --profile "$RUST_PROFILE" -p codex-mobile-client

echo "==> Done. Android JNI libs are in: $OUT_DIR"
